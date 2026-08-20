import PerunDBAL
import Testing

@Test
func sqlScannerRecognizesEveryTransactionControlCommand() {
    let cases: [(sql: String, command: String)] = [
        ("BEGIN", "BEGIN"),
        ("commit work", "COMMIT"),
        ("END", "END"),
        ("rollback to savepoint previous", "ROLLBACK"),
        ("ABORT", "ABORT"),
        ("SAVEPOINT nested", "SAVEPOINT"),
        ("RELEASE SAVEPOINT nested", "RELEASE"),
        ("START TRANSACTION", "START TRANSACTION"),
        ("prepare transaction 'migration'", "PREPARE TRANSACTION"),
        ("set transaction isolation level serializable", "SET TRANSACTION"),
        ("START /* gap */ TRANSACTION", "START TRANSACTION"),
        ("PREPARE -- gap\n TRANSACTION 'migration'", "PREPARE TRANSACTION"),
        ("SET /* outer /* nested */ still outer */ TRANSACTION", "SET TRANSACTION"),
    ]

    for value in cases {
        #expect(sqlTransactionControlCommand(in: value.sql) == value.command)
    }
}

@Test
func sqlScannerOnlyClassifiesTheFirstMeaningfulStatement() {
    let laterControlStatements = [
        "SELECT 1; COMMIT",
        "INSERT INTO samples VALUES (1); /* gap */ ROLLBACK",
        "UPDATE samples SET value = 1;; START TRANSACTION",
        "SELECT 1; PREPARE TRANSACTION 'migration'",
        "SELECT 1; SET TRANSACTION READ ONLY",
    ]

    for sql in laterControlStatements {
        #expect(sqlTransactionControlCommand(in: sql) == nil)
    }

    #expect(sqlTransactionControlCommand(in: "ROLLBACK; SELECT 1") == "ROLLBACK")
}

@Test
func sqlScannerSkipsLeadingSemicolonsWhitespaceAndComments() {
    let sql = """
        ; ; -- BEGIN;
        /* ordinary block comment */
        SAVEPOINT next
        """

    #expect(sqlTransactionControlCommand(in: sql) == "SAVEPOINT")
}

@Test
func sqlScannerSkipsUTF8ByteOrderMarksAnywhereInLeadingTrivia() {
    let cases: [(sql: String, command: String)] = [
        ("\u{FEFF}COMMIT", "COMMIT"),
        (" ; -- gap\n\u{FEFF} /* another gap */ ROLLBACK", "ROLLBACK"),
        ("\u{FEFF} \u{FEFF} SAVEPOINT next", "SAVEPOINT"),
    ]

    for value in cases {
        #expect(sqlTransactionControlCommand(in: value.sql) == value.command)
    }
}

@Test
func sqlScannerIgnoresControlInsideStringsAndQuotedIdentifiers() {
    let cases = [
        "SELECT 'BEGIN; COMMIT; ROLLBACK'",
        "SELECT 'one''; SET TRANSACTION; two'",
        #"SELECT E'one\'; COMMIT; two'"#,
        #"SELECT U&'one\0020; ROLLBACK; two'"#,
        "SELECT \"SAVEPOINT; RELEASE; END\" FROM samples",
        "SELECT `BEGIN; COMMIT` FROM samples",
        "SELECT [ROLLBACK; END] FROM samples",
    ]

    for sql in cases {
        #expect(sqlTransactionControlCommand(in: sql) == nil)
    }
}

@Test
func sqlScannerIgnoresControlInsidePostgresDollarQuotes() {
    let cases = [
        "DO $$ BEGIN PERFORM 1; COMMIT; END $$",
        "SELECT $migration$ SET TRANSACTION; ROLLBACK; $migration$",
        "SELECT $tag_2$ SAVEPOINT nested; RELEASE nested; $tag_2$",
    ]

    for sql in cases {
        #expect(sqlTransactionControlCommand(in: sql) == nil)
    }
}

@Test
func sqlScannerUsesBothNestedAndFlatBlockCommentSemantics() {
    #expect(
        sqlTransactionControlCommand(
            in: "/* outer /* nested */ COMMIT; -- */"
        ) == "COMMIT"
    )

    let postgresCases: [(sql: String, command: String)] = [
        ("/* outer /* nested */ still outer */ SAVEPOINT next", "SAVEPOINT"),
        ("/* outer /* nested */ still outer */ ROLLBACK", "ROLLBACK"),
    ]
    for value in postgresCases {
        #expect(sqlTransactionControlCommand(in: value.sql) == value.command)
    }
}

@Test
func sqlScannerIgnoresControlInsideLineAndBlockComments() {
    let cases = [
        "SELECT 1 -- ; COMMIT\n",
        "/* BEGIN; /* ROLLBACK; */ SELECT 1",
        "SELECT 1 /* SET TRANSACTION; /* SAVEPOINT nested; */ */",
    ]

    for sql in cases {
        #expect(sqlTransactionControlCommand(in: sql) == nil)
    }
}

@Test
func sqlScannerDoesNotJoinKeywordsAcrossStatementBoundaries() {
    let cases = [
        "START; TRANSACTION",
        "SET; TRANSACTION",
        "PREPARE; TRANSACTION",
    ]

    for sql in cases {
        #expect(sqlTransactionControlCommand(in: sql) == nil)
    }
}

@Test
func sqlScannerAllowsSafeBatchesAndKeywordPrefixes() {
    let cases = [
        "",
        " ; ; -- only trivia\n /* still trivia */ ; ",
        "SELECT 1; SELECT 2",
        "INSERT INTO samples VALUES (1); UPDATE samples SET value = 2",
        "BEGINNING OF QUERY",
        "START WORK",
        "PREPARE query AS SELECT 1",
        "SET application_name = 'transaction'",
    ]

    for sql in cases {
        #expect(sqlTransactionControlCommand(in: sql) == nil)
    }
}

@Test
func sqlScannerDoesNotInspectSQLiteTriggerBody() {
    let trigger = """
        CREATE TRIGGER audit_insert AFTER INSERT ON samples
        BEGIN
            INSERT INTO audit_log(message) VALUES ('BEGIN; COMMIT');
            UPDATE counters SET value = value + 1;
        END;
    """

    #expect(sqlTransactionControlCommand(in: trigger) == nil)
    #expect(sqlTransactionControlCommand(in: trigger + " COMMIT") == nil)
}

@Test
func postgresMeaningfulStatementCheckUsesNestedCommentsAndRejectsOnlyTrivia() {
    let emptyCases = [
        "",
        " \t\r\n ; ; ",
        "\u{FEFF} ; -- byte-order mark is trivia\n",
        "-- line comment\n /* block comment */ ;",
        "/* outer /* nested */ still outer */ -- trailing comment",
    ]
    for sql in emptyCases {
        #expect(!sqlContainsMeaningfulStatement(in: sql))
    }

    let meaningfulCases = [
        "SELECT 1",
        "; /* leading */ COMMIT",
        "/* outer /* nested */ still outer */ ROLLBACK",
        "/* unterminated block comment",
    ]
    for sql in meaningfulCases {
        #expect(sqlContainsMeaningfulStatement(in: sql))
    }
}
