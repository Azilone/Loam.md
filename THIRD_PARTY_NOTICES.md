# Third-party notices

Loam is MIT licensed (see [LICENSE](LICENSE)). It builds on the following projects, each under its own license.

## Swift packages

| Project | Version | License |
| --- | --- | --- |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | 0.9.0 | Apache-2.0 |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) | 0.9.0 | BSD-2-Clause |
| [Yams](https://github.com/jpsim/Yams) | 5.4.0 | MIT |
| [swift-crypto](https://github.com/apple/swift-crypto) | 3.15.1 | Apache-2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.6.0 | Apache-2.0 |

## Bundled JavaScript

| Project | Version | License | Full text |
| --- | --- | --- | --- |
| [Excalidraw](https://github.com/excalidraw/excalidraw), React, React DOM and their dependencies | 0.18.1 / 19.1.0 | MIT and others | `App/Sources/Plugins/ExcalidrawUI/Resources/excalidraw/LICENSE` |
| [Pele](https://github.com/obsidianmd/pele) | 1.6.0 | MIT | `App/Sources/Plugins/DiagramsUI/Resources/PELE-LICENSE` |

## Bundled Swift code

| Project | License | Full text |
| --- | --- | --- |
| Border beam (border-beam-native, [Libraries.dev](https://github.com/Jakubantalik/Libraries.dev)), ported in `App/Sources/BorderBeamKit` | MIT, (c) 2026 Jakub Antalik | `App/Sources/BorderBeamKit/LICENSE.md` |
| [Thinking orbs](https://libraries.dev/orbs) (Libraries.dev, `packages/thinking-orbs/ports/ios`), in `App/Sources/ThinkingOrbsKit` | MIT, (c) 2026 Jakub Antalik | `App/Sources/ThinkingOrbsKit/LICENSE.md` |

## Bundled icons

| Project | Version | License | Full text |
| --- | --- | --- | --- |
| [Lobe Icons](https://github.com/lobehub/lobe-icons) (`@lobehub/icons-static-svg`), the agent logos in `App/Sources/Plugins/AssistantUI/Resources/Logos` | 1.100.0 | MIT, (c) 2023 LobeHub | `App/Sources/Plugins/AssistantUI/Resources/Logos/LICENSE.md` |
| [Simple Icons](https://simpleicons.org) (`googlegemini`), the Antigravity mark | | CC0-1.0 | |

The agent logos are trademarks of their owners; Loam shows them only to name the tool you installed.

Swift package versions are those in `Package.resolved`. Excalidraw and React are pinned in `scripts/vendor-excalidraw.sh`,
and Pele in the header of its bundled file (`App/Sources/Plugins/DiagramsUI/Resources/pele.global.js`). Update this file with them.
