# Credits

Purrifier is an independent Swift reimplementation. It contains **no code copied** from the
projects below; it builds on the protocol knowledge they published, and uses two of them
(aioairctrl, aiocoap) as test oracles via `Tools/gen_vectors.py`. If code is ever copied, its
original license notice will be kept with it.

| Project | Authors | License | What Purrifier learned from it |
|---|---|---|---|
| [py-air-control](https://github.com/rgerganov/py-air-control) | Radoslav Gerganov (rgerganov) and contributors | MIT | Original reverse engineering of the encrypted CoAP scheme (`coap_client.py`): sync, counter, key/IV derivation, digest, framing. Also the earlier HTTP/DiComm work and the [xakcop.com write-up](https://xakcop.com/post/ctrl-air-purifier/) |
| [aioairctrl](https://github.com/kongo09/aioairctrl) (originally [betaboon/aioairctrl](https://github.com/betaboon/aioairctrl)) | betaboon, kongo09 and contributors | MIT | The async reference client; the oracle for Purrifier's crypto test vectors and the `--debug` comparison |
| [philips-airpurifier-coap](https://github.com/kongo09/philips-airpurifier-coap) (fork lineage via [Denaun](https://github.com/Denaun/philips-airpurifier) and betaboon) | kongo09, Denaun and contributors | see repository | Key generations (`const.py`), per-model mappings incl. AC0850 classes, and the community dumps in [issue #139](https://github.com/kongo09/philips-airpurifier-coap/issues/139) used as test fixtures |
| [ha-philips-airpurifier](https://github.com/ruaan-deysel/ha-philips-airpurifier) / [philips-airctrl](https://github.com/ruaan-deysel/philips-airctrl) | ruaan-deysel and contributors | Apache-2.0 / MIT | Discovery patterns, push-only firmware handling, firmware-update caveats |
| [com.athom.philipsair](https://github.com/biemond/com.athom.philipsair) | biemond and contributors | see repository | An independent JavaScript implementation, verified on an AC0850/11, for cross-checking |
| [aiocoap](https://github.com/chrysn/aiocoap) | chrysn and contributors | MIT | Golden CoAP datagrams for the codec tests |

Thanks also to the people who posted status dumps and debug logs in public issues. That is
what makes projects like this possible.

Purrifier is not affiliated with or endorsed by Philips or Versuni, or by any of the projects
above.
