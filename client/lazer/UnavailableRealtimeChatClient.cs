// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the official osu! source tree for full licence text.

using System;
using System.Collections.Generic;

namespace osu.Game.Online.Chat
{
    /// <summary>
    /// Keeps the normal chat surface initialised while a custom endpoint does not yet
    /// provide websocket chat. This deliberately performs no network retries.
    /// </summary>
    public sealed class UnavailableRealtimeChatClient : IChatClient
    {
        public event Action<Channel>? ChannelJoined
        {
            add { }
            remove { }
        }

        public event Action<Channel>? ChannelParted
        {
            add { }
            remove { }
        }

        public event Action<List<Message>>? NewMessages
        {
            add { }
            remove { }
        }

        public event Action? PresenceReceived;

        public void RequestPresence() => PresenceReceived?.Invoke();

        public void Dispose()
        {
        }
    }
}
