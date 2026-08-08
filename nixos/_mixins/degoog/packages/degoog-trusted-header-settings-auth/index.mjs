const USER_HEADER = "X-User";
const CALLBACK_PATH = "/api/settings/auth/callback";
const SETTINGS_PATH = "/settings";

let allowedUsers = new Set();

const normalizeUser = (user) => String(user || "").trim().toLowerCase();

const json = (body, status = 200) =>
  Response.json(body, {
    status,
    headers: { "cache-control": "no-store" },
  });

export const middleware = {
  name: "Trusted header settings authentication",
  isClientExposed: false,
  settingsSchema: [
    {
      key: "allowedUsers",
      label: "Allowed users",
      type: "text",
      required: true,
      description: "Comma-separated users accepted from the trusted X-User header",
    },
  ],

  configure(settings) {
    allowedUsers = new Set(
      String(settings.allowedUsers || "")
        .split(",")
        .map(normalizeUser)
        .filter(Boolean),
    );
  },

  async handle(request, context) {
    const user = normalizeUser(request.headers.get(USER_HEADER));
    const authorized = user && allowedUsers.has(user);

    if (!authorized) {
      if (context?.route === "settings-auth") {
        return json(
          {
            required: true,
            valid: false,
            loginUrl: "/",
          },
          403,
        );
      }
      return json({ ok: false, error: "Forbidden" }, 403);
    }

    if (context?.route === "settings-auth") {
      return json({
        required: true,
        valid: false,
        loginUrl: CALLBACK_PATH,
      });
    }

    if (context?.route === "settings-auth-callback") {
      return { redirect: SETTINGS_PATH };
    }

    if (context?.route === "settings-auth-post") {
      return json({ ok: false, error: "Use SSO login" }, 400);
    }

    return null;
  },
};

export default { middleware };
