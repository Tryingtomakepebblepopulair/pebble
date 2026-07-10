// The portable suite lineup, in pebsmoke's order so outputs diff cleanly.

/// Every golden suite that runs on PebbleCoreBase alone (PORTING module 13).
public func runPortableSmokeSuites() {
    smokeRandomSuite()
    smokeNoiseSuite()
    smokeMathSuite()
    smokeBlockRegistrySuite()
    smokeItemRegistrySuite()
    smokeBiomeSuite()
    smokeTerrainSuite()
    smokeFeatureSuite()
    smokeAtlasSuite()
    smokeMesherSuite()
    smokeWorldSimSuite()
    smokeItemsSuite()
    smokeFdlibmSuite()
    smokeEntitySuite()
    smokeSystemsSuite()
    smokePhysicsSuite()
    smokeRenderABISuite()
    smokeCodecSuite()
    smokeNetProtocolSuite()
    smokeSocketTransportSuite()
    smokeSocialSuite()
    smokePortableServerSuite()
}
