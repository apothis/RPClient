import Foundation

let suites: [TestSuite] = [
    promptBuilderTests(),
    templateTests(),
    chunkerTests(),
    vectorStoreTests(),
    chatCodableTests(),
    worldInfoEntryCodableTests(),
    worldInfoInjectorTests(),
    memoryAuditRegressionTests(),
]

exit(TestRunner.run(suites))
