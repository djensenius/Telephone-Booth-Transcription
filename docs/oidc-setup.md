# OIDC sign-in setup (Authentik)

Sign-in for the Review surface uses an Authentik OAuth2/OpenID provider shared
with [`Telephone-Booth-Operator-Mobile`][tbom]: same issuer, same client ID,
same scopes. Only the redirect URI differs, because each app owns its own
custom URL scheme.

[tbom]: https://github.com/djensenius/Telephone-Booth-Operator-Mobile

## What the app sends

Values come from `Info.plist` (`OIDCIssuerBase`, `OIDCClientID`,
`OIDCRedirectScheme`, `OIDCScopes`) and are read by
`AppAuthConfig` in `Sources/TranscriptionAuth/AppAuthConfig.swift`.

| Setting | Default |
| --- | --- |
| Issuer base | `https://auth.fluxhaus.io/application/o/telephone-booth-operator-mobile` |
| Client type | Public, PKCE (`S256`), no client secret |
| Grant types | `authorization_code`, `refresh_token` |
| Scopes | `openid email profile offline_access` |
| Redirect URI | `tbtranscription://oauth/callback` |

The redirect scheme is also declared in `CFBundleURLTypes` in
`Resources/TranscriptionApp-Info.plist` and
`Resources/TranscriptionAppiOS-Info.plist`. The two must stay in sync — the
scheme in `CFBundleURLTypes`, the `OIDCRedirectScheme` value, and the URI
registered on the provider.

Note that Authentik's `authorize` and `token` endpoints live at the *parent*
path of the per-app issuer (`/application/o/authorize/`,
`/application/o/token/`) and strict-match the trailing slash.

## Register the redirect URI

In the Authentik admin interface, open **Applications → Providers →** the
provider backing `telephone-booth-operator-mobile`, and add
`tbtranscription://oauth/callback` to **Redirect URIs/Origins**. Authentik 2024.x
and newer treat each line as a strict/regex match entry, so add it as its own
line alongside the Operator Mobile entry:

```text
tboperator://oauth/callback
tbtranscription://oauth/callback
```

Leave the match mode as **Strict** — a regex entry that accidentally matches
more than intended is an open-redirect risk.

## Troubleshooting

**"The request fails due to a missing, invalid, or mismatching redirection URI
(redirect_uri)."**

Authentik rejected the `redirect_uri` before showing a login prompt. The URI is
not registered on the provider. Verify from a shell:

```sh
curl -s -o /dev/null -w '%{http_code}\n' -G \
  'https://auth.fluxhaus.io/application/o/authorize/' \
  --data-urlencode 'client_id=<client id>' \
  --data-urlencode 'response_type=code' \
  --data-urlencode 'redirect_uri=tbtranscription://oauth/callback' \
  --data-urlencode 'scope=openid email profile offline_access' \
  --data-urlencode 'state=probe' \
  --data-urlencode 'nonce=probe' \
  --data-urlencode 'code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM' \
  --data-urlencode 'code_challenge_method=S256'
```

`302` means the URI is registered; `400` means it is not.

**The browser sheet opens, you sign in, and nothing comes back.**

The scheme in `CFBundleURLTypes` does not match `OIDCRedirectScheme`, so
`ASWebAuthenticationSession` never recognises the callback. Check both plists.

**Token exchange fails after a successful redirect.**

Authentik requires the same `redirect_uri` on the token request as on the
authorize request, and the provider must allow the `refresh_token` grant for
`offline_access` to return a refresh token.
