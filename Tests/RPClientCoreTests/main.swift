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
    helpIndexTests(),
    settingsServersCodableTests(),
    koboldClientRegistryTests(),
]

exit(TestRunner.run(suites))
