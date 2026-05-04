import Foundation

let suites: [TestSuite] = [
    promptBuilderTests(),
    templateTests(),
    chunkerTests(),
    vectorStoreTests(),
    chatCodableTests(),
    characterPersonaTests(),
    characterCardImporterTests(),
    turnVariantTests(),
    worldInfoEntryCodableTests(),
    worldInfoInjectorTests(),
    memoryAuditRegressionTests(),
]

exit(TestRunner.run(suites))
