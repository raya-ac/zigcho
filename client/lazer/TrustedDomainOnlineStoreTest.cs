// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the official osu! source tree for full licence text.

using NUnit.Framework;

namespace osu.Game.Online.Tests
{
    [TestFixture]
    public class TrustedDomainOnlineStoreTest
    {
        [TestCase("https://kai.ovh", true)]
        [TestCase("https://a.kai.ovh/3", true)]
        [TestCase("https://assets.kai.ovh/beatmaps/1/covers/cover.jpg", true)]
        [TestCase("https://assets.ppy.sh/menu-content.json", true)]
        [TestCase("http://a.kai.ovh/3", false)]
        [TestCase("https://kai.ovh.evil.test/3", false)]
        [TestCase("https://notkai.ovh/3", false)]
        [TestCase("data:image/png;base64,AAAA", false)]
        [TestCase("/relative/resource.png", false)]
        public void TestTrustedUrl(string url, bool expected)
        {
            Assert.That(TrustedDomainOnlineStore.IsTrustedUrl(url), Is.EqualTo(expected));
        }
    }
}
