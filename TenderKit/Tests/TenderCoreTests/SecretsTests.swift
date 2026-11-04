import Foundation
import Testing
import TenderCore

@Test func templatesFindServiceAndSharedReferences() throws {
    let refs = try SecretTemplate.references(in: "mongodb://app:${secret:MONGO_PASSWORD}@db/${secret:shared/DB_NAME}")
    #expect(refs == [SecretRef(name: "MONGO_PASSWORD"), SecretRef(name: "DB_NAME", shared: true)])
    #expect(refs.map(\.description) == ["MONGO_PASSWORD", "shared/DB_NAME"])
}

@Test func templatesRenderEscapesAndLeaveOtherDollarsAlone() throws {
    let values = ["X": "1", "shared/Y": "2"]
    let render = { (text: String) in try SecretTemplate.render(text) { values[$0.description] } }
    #expect(try render("a${secret:X}b${secret:shared/Y}c") == "a1b2c")
    #expect(try render("$${secret:X}") == "${secret:X}")
    #expect(try render("${HOME} $PATH $") == "${HOME} $PATH $")
    #expect(try render("plain") == "plain")
}

@Test(arguments: ["${secret:}", "${secret:1ABC}", "${secret:A-B}", "${secret:A", "${secret:shared/}", "${secret:other/X}"])
func malformedReferencesAreRejected(text: String) {
    #expect(throws: SecretTemplateError.self) { try SecretTemplate.references(in: text) }
}

@Test func aMissingValueNamesTheSecret() {
    #expect(throws: SecretTemplateError.missing(SecretRef(name: "GONE"))) {
        try SecretTemplate.render("${secret:GONE}") { _ in nil }
    }
}

@Test func onlyTemplatedSpecsNeedTheWrapper() throws {
    var spec = ServiceSpec(name: "api", program: .executable("/bin/sleep"), arguments: ["1"], environment: ["A": "b"])
    #expect(!spec.usesSecretTemplates)
    spec.environment["URL"] = "x${secret:PASS}"
    spec.arguments.append("--key=${secret:shared/KEY}")
    #expect(spec.usesSecretTemplates)
    #expect(try spec.secretRefs().map(\.description) == ["PASS", "shared/KEY"])
}

@Test func secretNamesRoundTripThroughPathsAndItems() throws {
    let service = try #require(SecretName(path: "api/MONGO_PASSWORD"))
    #expect(service.itemName == "svc.api.MONGO_PASSWORD")
    #expect(SecretName(itemName: service.itemName) == service)
    let shared = try #require(SecretName(path: "shared/JWT_KEY"))
    #expect(shared.scope == .shared && shared.itemName == "shared.JWT_KEY")
    #expect(SecretName(itemName: "shared.JWT_KEY") == shared)
    #expect(shared.description == "shared/JWT_KEY")
    for bad in ["api", "api/", "/X", "api/X/Y", "../X", "api/X.Y", "ap i/X"] {
        #expect(SecretName(path: bad) == nil)
    }
    #expect(SecretName(itemName: "ca.key") == nil)
}
