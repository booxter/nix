import assert from "node:assert/strict";
import test from "node:test";

import { middleware } from "./index.mjs";

const requestFor = (user) =>
  new Request("https://goo.ihar.dev/api/settings/auth", {
    headers: user ? { "X-User": user } : {},
  });

test.beforeEach(() => middleware.configure({ allowedUsers: "ihar" }));

test("offers the Degoog callback to an allowed user", async () => {
  const response = await middleware.handle(requestFor("IHAR"), {
    route: "settings-auth",
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    required: true,
    valid: false,
    loginUrl: "/api/settings/auth/callback",
  });
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("completes the callback for an allowed user", async () => {
  const result = await middleware.handle(requestFor("ihar"), {
    route: "settings-auth-callback",
  });

  assert.deepEqual(result, { redirect: "/settings" });
});

test("rejects a different authenticated user", async () => {
  const response = await middleware.handle(requestFor("kasia"), {
    route: "settings-auth",
  });

  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), {
    required: true,
    valid: false,
    loginUrl: "/",
  });
});

test("fails closed without an allowed-user configuration", async () => {
  middleware.configure({});

  const response = await middleware.handle(requestFor("ihar"), {
    route: "settings-auth-callback",
  });

  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), { ok: false, error: "Forbidden" });
});

test("does not accept password login while the SSO gate is active", async () => {
  const response = await middleware.handle(requestFor("ihar"), {
    route: "settings-auth-post",
  });

  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), {
    ok: false,
    error: "Use SSO login",
  });
});
