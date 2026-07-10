// Portable deterministic smoke — the cross-platform subset of pebsmoke.
// Runs every golden suite that needs only PebbleCoreBase, so Windows CI can
// prove worldgen/sim/protocol behavior is bit-identical to macOS (PORTING
// module 13). Apple-only suites (simd frustum, Network.framework LAN and
// dedicated-server e2e) stay in pebsmoke.

import Foundation
import PebbleSmokeKit

smokeBootstrapDataRoot()
runPortableSmokeSuites()

print("\n\(passed) passed, \(failed) failed")
// fail closed: zero checks means the suites never actually ran
exit(failed > 0 || passed == 0 ? 1 : 0)
