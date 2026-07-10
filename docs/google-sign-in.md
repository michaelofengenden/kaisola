# Google sign-in

Kaisola uses Google's desktop OAuth flow in the system browser with a loopback
callback, state, nonce, and PKCE. It never asks for a Google password and never
stores an access token or refresh token. After Google returns the identity, the
app stores only the local profile id, name, and email in `app-identity.json`.

The published build needs one Google Cloud OAuth client created as **Desktop
app**. Supply only its public client id in either location:

- build/runtime environment: `KAISOLA_GOOGLE_CLIENT_ID`
- packaged source or user data: `google-oauth.json` containing
  `{ "clientId": "...apps.googleusercontent.com" }`

Do not add a personal login, refresh token, service-account key, or client
secret. Desktop clients cannot keep secrets; PKCE protects the code exchange.
