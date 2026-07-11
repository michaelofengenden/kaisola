# Firebase-backed Google sign-in

Kaisola's desktop login is a three-step chain:

1. The app opens Google's **Desktop OAuth** flow in the system browser. A
   loopback callback, state, nonce, and PKCE protect the authorization code.
2. The main process exchanges Google's OAuth credential with Firebase Authentication.
   Firebase returns a short-lived Firebase ID token and a refresh token.
3. The app sends the Firebase ID token to the `session` Cloud Function. The
   Admin SDK verifies its signature, issuer, audience, expiry, disabled-user
   state, and revocation before writing the user's server-owned profile.

Only the refresh token is durable, encrypted with Electron `safeStorage` (the
OS keychain) in the main process. No Firebase token reaches React, localStorage,
the project workspace, logs, or Firestore client code. The untrusted renderer
can only ask main for a redacted status/profile.

Firestore remains deny-all for clients. `functions/index.js` uses the Admin SDK
and therefore does not depend on client Security Rules.

## Public desktop config

Copy `electron/firebase-config.example.json` to
`electron/firebase-config.json` and fill in:

- `projectId`: `kaisola-a9ab7`
- `apiKey`: a dedicated Firebase client key restricted to the APIs below
- `googleClientId`: a Google OAuth client of type **Desktop app**
- `serverUrl`: the deployed `session` function URL

The same values can be supplied at build/runtime through
`KAISOLA_FIREBASE_PROJECT_ID`, `KAISOLA_FIREBASE_API_KEY`,
`KAISOLA_GOOGLE_CLIENT_ID`, and `KAISOLA_AUTH_SERVER_URL`.

### API-key safety

A desktop application's Firebase key is visible to anyone who downloads the
app. It must therefore authorize only the Firebase APIs that the sign-in flow
uses:

- Identity Toolkit API (`identitytoolkit.googleapis.com`)
- Token Service API (`securetoken.googleapis.com`)

Never allow the Generative Language API (Gemini), Vertex AI, or another billed
non-Firebase API on this key. Use a separate server-side credential for those
services. If a client key ever allowed one of them, remove that API restriction
and rotate the key before publishing another build.

`electron/firebase-config.json` is generated and gitignored. For release
builds, add the rotated Firebase-only key as the GitHub Actions repository
secret `KAISOLA_FIREBASE_API_KEY`. Also add the Desktop OAuth JSON's
`client_secret` as `KAISOLA_GOOGLE_CLIENT_SECRET`. The workflow writes both
gitignored config files immediately before packaging. This keeps the values out
of source history, but it does not make them secret inside the distributed
desktop app—the Firebase API restrictions and OAuth PKCE are the security
boundaries.

Download the matching **Desktop app** OAuth credential JSON from Google Cloud
and save it as `electron/google-oauth.json`. That file is gitignored; Kaisola
reads its `installed.client_id` and `installed.client_secret` during the token
exchange. CI can instead provide `KAISOLA_GOOGLE_CLIENT_SECRET`. Google may
require this value even though an installed application cannot keep it
confidential, so PKCE remains required and is the protection for intercepted
authorization codes.

Never commit the OAuth JSON, a service-account JSON, personal access token, or
refresh token. Cloud Functions receives its service identity from Google at
runtime.

## Deploy

From the repository root, after `firebase login`:

```sh
firebase deploy --only functions:session,firestore:rules
```

The function creates/updates `users/{firebaseUid}` with name, email, provider,
`createdAt`, and `lastSeenAt`. It returns only the verified uid/name/email.

## Firebase / Google Console checklist

1. Authentication → Sign-in providers → Google: enabled (already shown in the
   supplied screenshot).
2. Project settings → General → Your apps: register a Web app if none exists,
   then copy its Web API Key into the desktop config.
3. Google Cloud → Google Auth Platform → Clients: create an OAuth client of type
   **Desktop app**, download its JSON, and save it as
   `electron/google-oauth.json`. Use that same JSON's client id in the public
   Firebase config; do not mix it with the Web client id.
4. Google Auth Platform → Branding: change the public-facing name from
   `project-60313772450` to `Kaisola`; keep the support email selected.
5. If the consent screen is in Testing, add intended testers. Publish to
   Production before offering sign-in broadly.
6. Cloud Functions deployment may require the Blaze plan. The Firebase CLI will
   say so before deployment.

Email/password and Phone are currently not exposed by Kaisola. Disable them
until their UI, recovery, abuse controls, and (for Phone) billing safeguards are
implemented. Google is the only provider this release consumes.
