#if canImport(SwiftUI)
import CatLaserDesign
import SwiftUI
import Testing

@Suite("CatLaserMotion")
struct CatLaserMotionTests {
    /// The helper honours reduced motion by returning `nil`. SwiftUI
    /// treats a `nil` animation as "no animation", so a view that
    /// writes `.animation(CatLaserMotion.animation(..., reduceMotion: true), value:)`
    /// transitions instantly.
    @Test
    func reduceMotionReturnsNil() {
        let result = CatLaserMotion.animation(.easeInOut, reduceMotion: true)
        #expect(result == nil)
    }

    /// When reduced motion is off, the supplied animation passes
    /// through unchanged.
    @Test
    func reduceMotionOffPassesAnimationThrough() {
        let result = CatLaserMotion.animation(.easeInOut, reduceMotion: false)
        #expect(result != nil)
    }
}
#endif
