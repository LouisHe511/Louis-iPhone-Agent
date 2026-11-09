# Upstream source

This separately built runner derives from [OpenMinis/iCTRL](https://github.com/OpenMinis/iCTRL), source tree `c1e4268859ba858d1579f7b846a56cb40641b7f6`, server version 1.98.16. Its Apache-2.0 license and third-party notices are retained in this directory. The upstream companion app, downloaded SDK frameworks and developer images are not included.

Local changes restrict the listener to loopback, disable remote/nearby controls and LAN self-checks, make status notifications passive, add display-session geometry tokens and native scale metadata, and optimize protocol-compatible byte processing. The parent app uses the authenticated v1 protocol. Pairing and system automation authorization remain required.

The runner uses private development/testing APIs and is not an App Store component. It must be signed separately, and it requires Developer Mode and prepared developer services. Do not commit signing identities, provisioning profiles, paired client keys or developer-image files.

The optional prebuilt Linux CLI is omitted from this source distribution. Use the included Python reference client or build the upstream CLI yourself.
