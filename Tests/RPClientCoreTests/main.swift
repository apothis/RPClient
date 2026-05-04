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
    retrievalEngineRoutingTests(),
    serverEditingTests(),
    serverProbeParseTests(),
]

exit(TestRunner.run(suites))
