"use strict";

const HOST_NAME = "com.yt_ingest.bookmarker";

browser.runtime.onMessage.addListener((message, _sender) => {
  if (message.action !== "bookmark") return;

  return browser.runtime.sendNativeMessage(HOST_NAME, message.entry)
    .then((response) => {
      return { ok: true, response };
    })
    .catch((err) => {
      console.error("Native messaging error:", err);
      return { ok: false, error: String(err) };
    });
});
