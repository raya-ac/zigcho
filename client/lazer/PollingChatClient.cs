// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the official osu! source tree for full licence text.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using osu.Framework.Logging;
using osu.Game.Online.API;

namespace osu.Game.Online.Chat
{
    /// <summary>
    /// Receives zigcho chat messages through the authenticated REST API while
    /// the websocket notification service is unavailable.
    /// </summary>
    public sealed class PollingChatClient : IChatClient
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
        public event Action<List<Message>>? NewMessages;
        public event Action? PresenceReceived;

        private readonly IAPIProvider api;
        private readonly CancellationTokenSource cancellation = new CancellationTokenSource();
        private long lastMessageId;
        private int started;
        private int presenceOnline;

        public PollingChatClient(IAPIProvider api)
        {
            this.api = api;
        }

        public void RequestPresence()
        {
            if (api.IsLoggedIn && Interlocked.Exchange(ref presenceOnline, 1) == 0)
                PresenceReceived?.Invoke();

            if (Interlocked.Exchange(ref started, 1) == 0)
                _ = Task.Run(poll, cancellation.Token);
        }

        private async Task poll()
        {
            while (!cancellation.IsCancellationRequested)
            {
                if (!api.IsLoggedIn)
                {
                    Interlocked.Exchange(ref presenceOnline, 0);
                    Interlocked.Exchange(ref lastMessageId, 0);
                    await delay(1000).ConfigureAwait(false);
                    continue;
                }

                if (Interlocked.Exchange(ref presenceOnline, 1) == 0)
                    PresenceReceived?.Invoke();

                var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                var request = new PollChatMessagesRequest(Interlocked.Read(ref lastMessageId));
                bool pollSucceeded = false;

                request.Success += messages =>
                {
                    if (messages.Count > 0)
                    {
                        advanceCursor(messages.Where(message => message.Id.HasValue).Select(message => message.Id ?? 0).DefaultIfEmpty(0).Max());
                        NewMessages?.Invoke(messages);
                    }

                    pollSucceeded = true;
                    completion.TrySetResult(true);
                };
                request.Failure += exception =>
                {
                    Logger.Log($"Chat poll failed: {exception.Message}", LoggingTarget.Network);
                    completion.TrySetResult(false);
                };

                api.Queue(request);

                try
                {
                    Task completed = await Task.WhenAny(completion.Task, Task.Delay(10000, cancellation.Token)).ConfigureAwait(false);
                    if (completed != completion.Task)
                    {
                        request.Cancel();
                        Logger.Log("Chat poll timed out.", LoggingTarget.Network);
                    }

                    await delay(pollSucceeded ? 1000 : 5000).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }

        private void advanceCursor(long value)
        {
            long current;
            do
            {
                current = Interlocked.Read(ref lastMessageId);
                if (value <= current)
                    return;
            }
            while (Interlocked.CompareExchange(ref lastMessageId, value, current) != current);
        }

        private async Task delay(int milliseconds)
        {
            try
            {
                await Task.Delay(milliseconds, cancellation.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
        }

        public void Dispose()
        {
            cancellation.Cancel();
        }

        private sealed class PollChatMessagesRequest : APIRequest<List<Message>>
        {
            private readonly long since;

            public PollChatMessagesRequest(long since)
            {
                this.since = since;
            }

            protected override string Target => $"chat/messages?since={since}";
        }
    }
}
