# Organizations with more members

For an organization, one App serves every member. Only one person runs `app create`; a second `app create` for the
same organization makes a second, duplicate App.

1. An organization owner (or App manager) runs `gh-touchid app create acme` and installs the App on the repositories
   members should reach.
2. For each member, the organization owner generates a client secret on the App's settings page. They hand it, with
   the App's client ID, to that member privately.
3. The member runs `gh-touchid app add acme --client-id Iv23li...`, enters the secret at the hidden prompt (or pipes
   it to stdin), and authorizes the App as themselves.

A member's tokens reach only repositories where the App is installed **and** the member has access. Removing the
member from the organization ends that. Also delete their client secret on the App's settings page.

Only organization owners and App managers can generate a private key for the App, which acts as the App's bot
([details](security-model.md#tokens-and-what-they-reach)). A member cannot.
