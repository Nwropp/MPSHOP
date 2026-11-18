/* MPSHOP · Service Worker
 * รับ Web Push จากเซิร์ฟเวอร์แล้วแสดง Notification แม้ผู้ใช้ไม่ได้เปิดเว็บไซต์
 * ไม่มี fetch handler จึงไม่แตะการโหลดหน้าเว็บปกติของร้าน
 */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let d = {};
  try {
    d = event.data ? event.data.json() : {};
  } catch (e) {
    d = { title: "MPSHOP", body: event.data ? event.data.text() : "" };
  }
  const title = d.title || "MPSHOP";
  const options = {
    body: d.body || "",
    icon: "icon-192.png",
    badge: "icon-192.png",
    image: d.image || undefined,
    tag: d.tag || undefined,
    renotify: false,
    data: { id: d.id || "", link: d.link || "", kind: d.kind || "" },
    vibrate: [90, 40, 90],
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const d = event.notification.data || {};
  const scope = self.registration.scope;
  let url = scope;
  if (/^https:\/\//i.test(d.link || "")) {
    url = d.link;                                   // ลิงก์ภายนอก (ถ้าแอดมินตั้งไว้)
  } else {
    url = scope + "?n=" + encodeURIComponent(d.id || "");
    if (/^#/.test(d.link || "")) url += d.link;      // เปิดไปยังออเดอร์/โปรโมชั่นที่เกี่ยวข้อง
  }

  event.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of list) {
      if (c.url.startsWith(scope)) {
        try { await c.focus(); } catch (e) {}
        try { c.postMessage({ type: "mpshop-notif", id: d.id, link: d.link }); } catch (e) {}
        return;
      }
    }
    if (self.clients.openWindow) return self.clients.openWindow(url);
  })());
});
