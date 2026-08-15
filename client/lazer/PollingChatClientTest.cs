// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the official osu! source tree for full licence text.

using System.Threading.Tasks;
using Moq;
using NUnit.Framework;
using osu.Game.Online.API;
using osu.Game.Online.Chat;

namespace osu.Game.Online.Tests
{
    [TestFixture]
    public class PollingChatClientTest
    {
        [Test]
        public async Task TestPresenceWaitsForLoginAndStartsPolling()
        {
            bool loggedIn = false;
            var api = new Mock<IAPIProvider>();
            api.SetupGet(provider => provider.IsLoggedIn).Returns(() => loggedIn);

            using var client = new PollingChatClient(api.Object);
            var presence = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            client.PresenceReceived += () => presence.TrySetResult();

            client.RequestPresence();
            await Task.Delay(100);
            Assert.That(presence.Task.IsCompleted, Is.False);

            loggedIn = true;
            Assert.That(await Task.WhenAny(presence.Task, Task.Delay(5000)), Is.SameAs(presence.Task));
            api.Verify(provider => provider.Queue(It.IsAny<APIRequest>()), Times.AtLeastOnce);
        }
    }
}
