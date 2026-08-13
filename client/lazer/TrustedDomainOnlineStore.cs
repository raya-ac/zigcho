// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the official osu! source tree for full licence text.

using System;
using osu.Framework.IO.Stores;
using osu.Framework.Logging;

namespace osu.Game.Online
{
    public sealed class TrustedDomainOnlineStore : OnlineStore
    {
        protected override string GetLookupUrl(string url)
        {
            if (!IsTrustedUrl(url))
            {
                Logger.Log($@"Blocking resource lookup from external website: {url}", LoggingTarget.Network, LogLevel.Important);
                return string.Empty;
            }

            return url;
        }

        internal static bool IsTrustedUrl(string url) =>
            Uri.TryCreate(url, UriKind.Absolute, out Uri? uri)
            && string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            && (isDomainOrSubdomain(uri.Host, "kai.ovh") || isDomainOrSubdomain(uri.Host, "ppy.sh"));

        private static bool isDomainOrSubdomain(string host, string domain) =>
            host.Equals(domain, StringComparison.OrdinalIgnoreCase)
            || host.EndsWith($".{domain}", StringComparison.OrdinalIgnoreCase);
    }
}
