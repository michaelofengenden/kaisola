# Mobile Google sign-in — OAuth redirect fix

**Status:** blocker identified by review; deployable pieces ready; needs one
deploy step + a device test to finish.

## Problem (confirmed by review)

The iOS `FirebaseAuthBackend` mirrors the desktop's Firebase Identity Toolkit
REST flow but uses a **custom-scheme** `continueUri` of `kaisola://auth`. Firebase
requires `continueUri` to be an **http(s) URL on an authorized domain**. The
desktop only works because `http://localhost` is auto-authorized; a custom scheme
is not. So `accounts:createAuthUri` either 400s or the `firebaseapp.com/__/auth/
handler` refuses to redirect to `kaisola://`, and sign-in never completes on a
real device.

## Chosen fix: an https redirector on an auto-authorized domain

Firebase auto-authorizes `PROJECT.web.app` and `PROJECT.firebaseapp.com`. We host
a tiny bounce page there that forwards the OAuth result to the app's custom
scheme, which `ASWebAuthenticationSession` intercepts.

Deployable pieces (in this repo, ready):
- `hosting/companion-auth.html` — the bounce page: `location.replace('kaisola://
  auth' + search + hash)`. Stores/inspects nothing.
- `firebase.json` — hosting config with a rewrite `/companion-auth →
  companion-auth.html`.

Resulting authorized `continueUri`: `https://kaisola-a9ab7.web.app/companion-auth`

## Remaining steps

1. **Deploy the redirector (one-time, needs your Firebase login):**
   ```bash
   npx firebase-tools login       # your Google account for kaisola-a9ab7
   npx firebase-tools deploy --only hosting
   ```
   (Or authorize Claude to run these.)
2. **Swift change** in `FirebaseAuthBackend.swift`: set
   `continueURI = https://kaisola-a9ab7.web.app/companion-auth`, keep
   `ASWebAuthenticationSession(callbackURLScheme: "kaisola")`, and pass the
   redirector `continueUri` as `requestUri` to `signInWithIdp` (the credential
   params ride through to the `kaisola://auth` callback the page forwards).
3. **Device test:** run on a physical iPhone (or a simulator with the scheme
   registered), sign in, confirm the callback resolves and a session is minted.

## Alternative considered

Native **GoogleSignIn iOS SDK** with an iOS-type OAuth client (reversed client
id, which Google accepts natively — no redirector). Rejected for now: adds an SDK
dependency and needs an iOS OAuth client registered in the Google Cloud console
(a comparable one-time console step), whereas the redirector reuses the existing
Firebase project and REST flow already reviewed clean for secret handling.

## Note

This gates on-device sign-in only. The crypto, transport, pairing spine, and the
whole SwiftUI experience are unaffected and verified. Until this ships, the app
signs in only via the `KAISOLA_UI_PREVIEW` debug path (screenshots/dev).
