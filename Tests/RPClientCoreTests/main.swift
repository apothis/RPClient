import Foundation

let suites: [TestSuite] = [
    promptBuilderTests(),
    templateTests(),
    chunkerTests(),
    vectorStoreTests(),
    chatCodableTests(),
    worldInfoEntryCodableTests(),
    memoryAuditRegressionTests(),
]

exit(TestRunner.run(suites))
