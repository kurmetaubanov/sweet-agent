# The tests are run WITHOUT bringing up the application: `mix test --no-start`.
#
# The reason is direct: `Sweet.Application` brings up a listener on a port, creates the
# container of the embedder and climbs into docker. To check pure functions at the price of a
# raised stack is a bad trade, and on CI there may be no docker at all.
#
# But an UN-raised application and UN-raised processes are different things. The processes
# which need neither the network nor docker are brought up by the suite itself, through
# `start_supervised!`: the memory of a conversation, the inventory of sessions and the session itself are checked
# alive — otherwise the very thing for which they exist (the order of messages, who waits for
# whom, what remains after a stop) would not be checked at all.
#
# The boundary runs along the external world: the model, docker and Telegram do not come in here.
# So the hand, the embedder, a whole turn and the bridge into the chat are NOT covered by this suite and
# are checked on a live stack.
ExUnit.start()
