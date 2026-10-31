import Testing
@testable import TenderCore

@Test func serviceLabelFormat() {
    let label = TenderEnvironment.production.serviceLabel(service: "api", instance: 0)
    #expect(label == "com.olympsis.tender.svc.api.0")
}
