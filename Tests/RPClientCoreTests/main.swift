import Foundation

let suites: [TestSuite] = [
    promptBuilderTests(),
    templateTests(),
    chunkerTests(),
    vectorStoreTests(),
    chatCodableTests(),
    turnVariantTests(),
    worldInfoEntryCodableTests(),
    worldInfoInjectorTests(),
    memoryAuditRegressionTests(),
]

exit(TestRunner.run(suites))
