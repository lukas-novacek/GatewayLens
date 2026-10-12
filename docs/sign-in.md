# Sign-in

GatewayLens signs in as **you**, in your browser, on Microsoft's own sign-in page.
It can do exactly what your account can do in the Power BI and Fabric portals -
[permissions.md](permissions.md) has the details.

## The ways in

GatewayLens uses whichever works with nothing more to do:

| | You need | Your organisation approves GatewayLens |
|---|---|---|
| **Az.Accounts** - used when it is installed | `Install-Module Az.Accounts -Scope CurrentUser`, once. No admin rights. | No - Microsoft's Azure PowerShell is already approved in practically every tenant |
| **Your organisation's app registration** | `-ClientId <application id>` - see [below](#your-own-app-registration) | Once, by IT |
| **Built-in** - not published yet | Nothing | Once, the first time anyone in the organisation uses it |

> [!NOTE]
> GatewayLens's own app registration is not published yet, so the built-in way has
> nothing to sign in with. Until it is: install Az.Accounts - the quickest way - or
> start GatewayLens with your organisation's own app registration and `-ClientId`.

`-SignIn AzAccounts` or `-SignIn Browser` chooses one way. A `-ClientId` given on
the command line always means the built-in way.

With Az.Accounts, the sign-in logs show *Microsoft Azure PowerShell*, because that
is what signed you in. A few organisations restrict Azure PowerShell to
administrators; there, the built-in way is the one that works.

## How the built-in sign-in works

1. GatewayLens opens your browser at Microsoft's sign-in page.
2. You sign in. On a company PC this usually happens without a password, because
   Edge and Chrome already know your Windows account.
3. The browser hands a one-time code back to GatewayLens, and the tab says you are
   signed in. GatewayLens listens for that code on this computer only - nothing
   outside it can connect.
4. GatewayLens trades the code for tokens - one for Fabric, one for Power BI, one
   for Microsoft Graph - and renews them while the window is open. They stay in
   memory and are gone when the window closes.

Options:

```powershell
.\GatewayLens.ps1 -Account admin.jane@contoso.com   # a separate admin account
.\GatewayLens.ps1 -TenantId contoso.onmicrosoft.com # a guest account in another tenant
.\GatewayLens.ps1 -DeviceCode                       # no browser here: sign in on another device
```

## The first time with the built-in sign-in: your organisation approves GatewayLens

Like any app that signs in with Microsoft, GatewayLens is a registered application,
and your organisation decides whether its people may use it. The first sign-in
shows Microsoft's page *"GatewayLens wants to..."*, listing what it asks for.

- **If you may approve apps yourself**, click Accept. That is all.
- **If you see "Need admin approval"**, your organisation only lets administrators
  approve apps. Forward the next section to your IT team. It takes them a minute,
  once, for everyone. Until then, Az.Accounts is the way in.

### For IT: approving GatewayLens

GatewayLens is a public client - a desktop app with no secret and no certificate.
It acts only as the signed-in user, with that user's own permissions (delegated
permissions only, no application permissions). It talks to the Fabric, Power BI and
Microsoft Graph APIs and to nothing else.

To approve it for everyone, a Global Administrator, Cloud Application Administrator
or Application Administrator does **one** of these:

- Start GatewayLens and sign in. On the approval page, tick **Consent on behalf of
  your organization** and click Accept.
- Or, after anyone has tried to sign in once: Microsoft Entra admin center >
  **Enterprise applications** > GatewayLens > **Permissions** > **Grant admin
  consent**.

What it asks for, and why:

| API | Permission | Used for |
|---|---|---|
| Power BI Service | `Gateway.ReadWrite.All` | Gateways, members, gateway access |
| Power BI Service | `Connection.ReadWrite.All` | Connections, connection access, delete |
| Power BI Service | `Dataset.ReadWrite.All` | Connection test, update credentials (Power BI REST API) |
| Microsoft Graph | `User.Read` | Signing in, the signed-in user's own name |
| Microsoft Graph | `Directory.Read.All` | The names of the people, groups and apps in access lists - Fabric gives only their object ids |
| Microsoft Graph | `User.ReadBasic.All` | Finding a user by email when granting access |
| Microsoft Graph | `GroupMember.Read.All` | Finding a group by name when granting access |
| Microsoft Graph | `Application.Read.All` | Finding a service principal by name when granting access |

All of them are delegated: GatewayLens can never do more than the person using it.
Without the Graph permissions, everything works except names: the access lists
show object ids, and access is granted by object id.

Sign-in policies (Conditional Access, MFA) apply to GatewayLens like to any other
app. If one blocks it, the error names the policy check that failed.

## Your own app registration

An organisation that prefers its own registration over the built-in one can create
it and start GatewayLens with `-ClientId <application id>`. The steps are the same
as for the built-in one, below, except that *Accounts in this organizational
directory only* is enough.

## For the maintainer: the built-in app registration

The client id built into GatewayLens is that of one multi-tenant app registration,
kept by the GatewayLens maintainer. To create it:

1. Microsoft Entra admin center > **App registrations** > **New registration**.
   - Name: **GatewayLens**
   - Supported account types: **Accounts in any organizational directory
     (Any Microsoft Entra ID tenant - Multitenant)**
   - Redirect URI: platform **Public client/native (mobile & desktop)**,
     value `http://localhost`. Entra ignores the port for `localhost`, so the one
     GatewayLens picks each time always matches.
2. **Authentication** > **Advanced settings** > **Allow public client flows**:
   **Yes**. Device code sign-in needs it.
3. **API permissions** > **Add a permission** > the delegated permissions in the
   table above. In the portal, Power BI Service is under *Microsoft APIs*. Do not
   grant admin consent here - that would only approve it for the maintainer's own
   tenant.
4. **Certificates & secrets**: nothing. A public client has no secret.
5. Optional, recommended: **Branding & properties** > publisher verification. An
   unverified app shows as *unverified* on the approval page, and many
   organisations only let administrators approve unverified apps. Verification
   needs a Microsoft AI Cloud Partner Program account.
6. Copy the **Application (client) id** from the Overview page into
   `GatewayLens.ps1`, on the one line marked `# public-client-id`:

   ```powershell
   $script:BuiltInClientId = '<application id>'   # public-client-id
   ```

   A client id is not a secret - every sign-in page shows it. The tests allow a
   GUID on that marked line and nowhere else.

Then run `.\GatewayLens.ps1 -SelfTest` against a real tenant. It checks every call
once, including the two unofficial Power BI v2 endpoints, which may answer
differently for an app other than the portal's own.

## When sign-in fails

The message says what happened and what to do. The common ones:

| Message mentions | What it means |
|---|---|
| not approved yet (AADSTS65001, AADSTS90094) | Your organisation has not approved GatewayLens - see *For IT* above, or install Az.Accounts |
| no way to sign in on this computer | Neither way is available - install Az.Accounts, or use `-ClientId` |
| Az.Accounts is not installed | `-SignIn AzAccounts` was chosen - install it, or leave `-SignIn` out |
| a sign-in policy (AADSTS53003) | Conditional Access blocked the sign-in - your IT team can see which policy |
| not part of that organisation (AADSTS50020) | Start with `-TenantId` and your organisation's domain |
| the sign-in has expired | Restart GatewayLens to sign in again |
| did not finish within 5 minutes | The browser tab was closed or never opened - start again, or use `-DeviceCode` |
| no app registration to sign in with | This copy has no built-in client id - use `-ClientId` |
