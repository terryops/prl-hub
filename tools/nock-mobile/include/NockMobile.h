// NockMobile — Nockchain (NOCK) wallet core for Pearl Hub (Rust, tools/nock-mobile).
//
// One JSON-in / JSON-out entry point. `request` is UTF-8 JSON {"op": "...", ...params};
// the reply is {"ok": ...} or {"error": "...", "code": "..."}. Free every reply with
// nock_free. Pure computation: no network, no disk, safe to call from any thread.
#ifndef NOCK_MOBILE_H
#define NOCK_MOBILE_H

#ifdef __cplusplus
extern "C" {
#endif

char *nock_call(const char *request);
void nock_free(char *reply);

#ifdef __cplusplus
}
#endif

#endif
