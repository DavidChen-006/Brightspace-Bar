# Experiment 11 — does Purdue's tenant permit a TOTP method?

TOTP (time-based one-time password — the rotating 6-digit code) is the only
known path to **k = 0**: the code is computed from a stored secret plus the
clock, so a script can authenticate with no phone and no human. Whether it is
permitted is *tenant policy*, so this probe asks Microsoft directly.

**Strictly read-only.** It enumerates what is offered and stops. Registering a
method changes how an account signs in — a human decision, never an agent's.

```sh
npm run probe            # headless: reuses the persistent Entra profile
HEADED=1 npm run probe   # visible, and waits for a phone approval
```

## Findings

**1. Security Info is a step-up surface — the 90-day session is deliberately
not enough.** Navigating to `mysignins.microsoft.com/security-info` redirects
through an `authorize` URL that demands:

```
claims={"id_token":{"amr":{"essential":true,"values":["mfa","ngcmfa"]}}}
```

`ngcmfa` means *recent* MFA. So the Entra cookie that silently mints Brightspace
sessions all semester (experiment 10) is intentionally insufficient for changing
security settings. This is correct security design, and it is a hard wall for
automation: **the account's own auth configuration cannot be reached without a
fresh human factor.**

**2. Purdue's tenant DOES offer a verification-code method.** The step-up
picker enumerated:

```
Approve a request on my Outlook mobile app
Use a verification code
Text +X XXX-XXX-XX30
Call +X XXX-XXX-XX30
```

"Use a verification code" is the TOTP method. Its presence proves the tenant
**accepts TOTP codes for authentication** — the policy-level "no" that would
have killed the k=0 path does not apply here.

**3. What remains unproven: registration.** Accepting a TOTP code is not the
same as letting you *register a new authenticator and be shown the secret*. Our
script needs the secret string (normally hidden behind "Can't scan the QR
code?" during setup). Reaching that dialog requires clearing the `ngcmfa` wall
and then adding a method — an account change.

## Why the automation stops here, deliberately

Two independent reasons, and they agree:

1. **It cannot work unattended by design.** `ngcmfa` exists precisely to stop
   a held credential from editing the credentials. Any script reaching that
   page needs a live human factor at that moment, so automating it buys
   nothing.
2. **It should not be automated.** Adding an MFA method changes the security
   posture of a real person's university account. That is the human's call,
   made with their eyes on the screen.

The probe therefore reports what is offered and exits. The remaining check is
two minutes in a normal browser: **mysignins.microsoft.com → Security info →
Add sign-in method → Authenticator app → "I want to use a different
authenticator app"**. If that path shows a QR code with a "Can't scan image?"
link revealing a secret key, k = 0 is reachable and the display-the-number
feature never needs to be built. If the option is absent, the number-match
relay (proven readable in experiment 10) is the ceiling.
