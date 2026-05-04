import Foundation

let suites: [TestSuite] = [
    promptBuilderTests(),
    templateTests(),
    chunkerTests(),
    vectorStoreTests(),
    chatCodableTests(),
    memoryAuditRegressionTests(),
]

exit(TestRunner.run(suites))
