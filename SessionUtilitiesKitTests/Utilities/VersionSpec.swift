// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class VersionSpec: QuickSpec {
    override class func spec() {
        // MARK: - a Version
        describe("a Version") {
            // MARK: -- can be created from a string
            it("can be created from a string") {
                let version: Version = Version.from("1.20.3")
                
                expect(version.major).to(equal(1))
                expect(version.minor).to(equal(20))
                expect(version.patch).to(equal(3))
            }
            
            // MARK: -- correctly exposes a string value
            it("correctly exposes a string value") {
                let version: Version = Version(major: 1, minor: 20, patch: 3)
                
                expect(version.stringValue).to(equal("1.20.3"))
            }
            
            // MARK: -- when checking equality
            context("when checking equality") {
                // MARK: ---- returns true if the values match
                it("returns true if the values match") {
                    let version1: Version = Version.from("1.0.0")
                    let version2: Version = Version.from("1.0.0")
                    
                    expect(version1 == version2)
                        .to(beTrue())
                }
                
                // MARK: ---- returns false if the values do not match
                it("returns false if the values do not match") {
                    let version1: Version = Version.from("1.0.0")
                    let version2: Version = Version.from("1.0.1")
                    
                    expect(version1 == version2)
                        .to(beFalse())
                }
            }
            
            // MARK: -- when comparing versions
            context("when comparing versions") {
                // MARK: ---- returns correctly for a simple major difference
                it("returns correctly for a simple major difference") {
                    let version1: Version = Version.from("1.0.0")
                    let version2: Version = Version.from("2.0.0")
                    
                    expect(version1 < version2).to(beTrue())
                    expect(version2 > version1).to(beTrue())
                }
                
                // MARK: ---- returns correctly for a complex major difference
                it("returns correctly for a complex major difference") {
                    let version1a: Version = Version.from("2.90.90")
                    let version2a: Version = Version.from("10.0.0")
                    let version1b: Version = Version.from("0.7.2")
                    let version2b: Version = Version.from("5.0.2")
                    
                    expect(version1a < version2a).to(beTrue())
                    expect(version2a > version1a).to(beTrue())
                    expect(version1b < version2b).to(beTrue())
                    expect(version2b > version1b).to(beTrue())
                }
                
                // MARK: ---- returns correctly for a simple minor difference
                it("returns correctly for a simple minor difference") {
                    let version1: Version = Version.from("1.0.0")
                    let version2: Version = Version.from("1.1.0")
                    
                    expect(version1 < version2).to(beTrue())
                    expect(version2 > version1).to(beTrue())
                }
                
                // MARK: ---- returns correctly for a complex minor difference
                it("returns correctly for a complex minor difference") {
                    let version1a: Version = Version.from("90.2.90")
                    let version2a: Version = Version.from("90.10.0")
                    let version1b: Version = Version.from("2.0.7")
                    let version2b: Version = Version.from("2.5.0")
                    
                    expect(version1a < version2a).to(beTrue())
                    expect(version2a > version1a).to(beTrue())
                    expect(version1b < version2b).to(beTrue())
                    expect(version2b > version1b).to(beTrue())
                }
                
                // MARK: ---- returns correctly for a simple patch difference
                it("returns correctly for a simple patch difference") {
                    let version1: Version = Version.from("1.0.0")
                    let version2: Version = Version.from("1.0.1")
                    
                    expect(version1 < version2).to(beTrue())
                    expect(version2 > version1).to(beTrue())
                }
                
                // MARK: ---- returns correctly for a complex patch difference
                it("returns correctly for a complex patch difference") {
                    let version1a: Version = Version.from("90.90.2")
                    let version2a: Version = Version.from("90.90.10")
                    let version1b: Version = Version.from("2.5.0")
                    let version2b: Version = Version.from("2.5.7")
                    
                    expect(version1a < version2a).to(beTrue())
                    expect(version2a > version1a).to(beTrue())
                    expect(version1b < version2b).to(beTrue())
                    expect(version2b > version1b).to(beTrue())
                }
            }
        }
    }
}
