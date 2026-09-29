#!/usr/bin/env python3
"""Print the web app's Vercel environment (KEY=value lines, ready to paste into Vercel's "Import .env").

The web reads the chain, the contracts' addresses and the site settings from the API at runtime (`GET /v1/site`),
so its env is static: set it once, before the contracts exist.

    contracts/script/vercel-env.py --api https://api.flipper.family [--site https://flipper.family] \
        [--walletconnect <reown project id>] [--walletconnect-verification <code>] [--sentry-dsn <dsn>]
"""
import argparse

ap = argparse.ArgumentParser()
ap.add_argument("--api", required=True, help="the Go API's public URL (Railway)")
ap.add_argument("--site", default="https://flipper.family")
ap.add_argument("--walletconnect", default="", help="Reown project id")
ap.add_argument("--walletconnect-verification", default="", help="Reown's domain verification code")
ap.add_argument("--sentry-dsn", default="", help="optional: Sentry is on only when set")
a = ap.parse_args()

env = [
    ("NEXT_PUBLIC_API_URL", a.api.rstrip("/")),
    ("NEXT_PUBLIC_SITE_URL", a.site.rstrip("/")),
    ("NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID", a.walletconnect),
    # server-only
    ("WALLETCONNECT_DOMAIN_VERIFICATION", a.walletconnect_verification),
    ("ENABLE_EXPERIMENTAL_COREPACK", 1),
]
if a.sentry_dsn:
    env.append(("NEXT_PUBLIC_SENTRY_DSN", a.sentry_dsn))
print("# flipper.family web (Vercel). NEXT_PUBLIC_* are baked in at build time: redeploy after changing them.")
print("# The contracts come from the API at runtime. Never set NEXT_PUBLIC_DEV_MODE, KEEPER_API_URL or any DEV_*.")
for k, v in env:
    print("%s=%s" % (k, v))
