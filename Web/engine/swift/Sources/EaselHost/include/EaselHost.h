#ifndef EASEL_HOST_H
#define EASEL_HOST_H

#include <stdint.h>

// What the engine asks of the page it runs in (Web/engine/engine.js):
// setting type, which only the browser can do. A request is UTF-8 JSON;
// the call returns the length of its answer, which easel_host_result then
// copies out, or a negative number when the host can't answer.

__attribute__((import_module("easel"), import_name("text")))
int32_t easel_host_text(const uint8_t *request, int32_t length);

__attribute__((import_module("easel"), import_name("result")))
void easel_host_result(uint8_t *destination);

#endif
