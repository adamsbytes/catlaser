#if canImport(UIKit) && !os(watchOS)
import CatLaserDesign
import Foundation
import Testing
import UIKit

/// Behaviour tests for the orientation-lock state machine.
///
/// Exercises the mask transition contract. The UIKit
/// ``requestGeometryUpdate`` bridge is best-effort (returns silently
/// when no scene is available, which is the state the test runner
/// presents) and the test does not assert on the physical window.
@MainActor
@Suite("OrientationLock")
struct OrientationLockTests {
    /// Shared state across tests is intentional — the production
    /// ``OrientationLock.shared`` is a process-global singleton by
    /// design (see the docstring) and the tests ensure each
    /// transition lands regardless of the prior test's residue.
    private let lock = OrientationLock.shared

    @Test
    func allowUpdatesMask() async {
        lock.lockToPortrait()
        #expect(lock.mask == .portrait)

        lock.allow(.allButUpsideDown)
        #expect(lock.mask == .allButUpsideDown)
    }

    @Test
    func lockToPortraitRestoresPortraitMask() async {
        lock.allow(.landscape)
        #expect(lock.mask == .landscape)
        lock.lockToPortrait()
        #expect(lock.mask == .portrait)
    }

    @Test
    func allowIsIdempotentForSameMask() async {
        lock.allow(.allButUpsideDown)
        let first = lock.mask
        lock.allow(.allButUpsideDown)
        #expect(lock.mask == first)
    }

    @Test
    func allowHandlesTransitionBetweenDistinctMasks() async {
        lock.lockToPortrait()
        lock.allow(.landscape)
        #expect(lock.mask == .landscape)
        lock.allow(.portrait)
        #expect(lock.mask == .portrait)
    }
}
#endif
