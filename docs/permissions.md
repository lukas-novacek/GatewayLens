# What your account needs

GatewayLens acts as **you**. It can see and change exactly what your account can
in the Power BI and Fabric portals - no more. The only set-up is a one-time
approval of GatewayLens by your organisation - see [sign-in.md](sign-in.md).

The quickest way to find out what works for you is:

```powershell
.\GatewayLens.ps1 -SelfTest
```

## Roles

Gateways and connections each have their own roles. The names below are the
ones the Fabric API uses.

**On a gateway**

| Role | What it allows |
|---|---|
| `Admin` | Manage the gateway, its members and who has access to it |
| `ConnectionCreatorWithResharing` | Create connections on the gateway and let others do the same |
| `ConnectionCreator` | Create connections on the gateway |

**On a connection**

| Role | What it allows |
|---|---|
| `Owner` | Manage the connection, including who has access to it |
| `UserWithReshare` | Use the connection and share it with others |
| `User` | Use the connection |

## What each feature needs

| Feature | You need |
|---|---|
| See a gateway or connection | Any role on it |
| See gateway members | A role on the gateway; Admin to see everything |
| See and change gateway access | Admin on the gateway |
| See and change connection access | Owner of the connection |
| Test a connection | A role on the connection |
| Live member status | Admin on the gateway |
| Enable or disable a member | Admin on the gateway |
| Update a connection's credentials | Owner of the connection, or Admin on its gateway - the same both ways, like the portal or documented |
| Delete a connection | Owner of the connection |
| Hand over access (copy or move roles) | Owner of each connection; Admin on each gateway (with *Gateway clusters too*) |
| Access report | Owner of each connection and Admin on each gateway - for any other, its row says it could not be read |
| Connection recency | Comes with the connections list - Microsoft decides which connections carry it for your account (preview) |
| Connections per cluster | Nothing extra - the count is what your account can see, so a cluster can hold more |
| Usernames and access in one call | Admin on the gateways concerned |
| Grant access by name or email | Permission to read users and groups in Microsoft Graph - normal for members of most tenants |
| Names in access lists | Permission to read the directory in Microsoft Graph - without it, the lists show object ids |

These follow Microsoft's role model. The exact rule for any single call is in
Microsoft's REST API reference; when in doubt, the self-test shows what actually
happens for your account.

## Seeing every gateway in the tenant

The Fabric API lists the gateways and connections **you** hold a role on. Being a
Fabric or Power BI administrator does not by itself make every gateway visible.
To work with a gateway, ask one of its admins to add you.

## Microsoft Graph

Fabric says who has access by object id only. GatewayLens asks Microsoft Graph for
the names, up to 1,000 in one call, and remembers them while the window is open.

Granting access by name ("jane@contoso.com", "BI Team") turns the name into an
object id through Microsoft Graph too. If your organisation has not approved the
Graph permissions for GatewayLens, the access lists show object ids, and you paste
an object id to grant access or hand it over - you will find it in the Microsoft
Entra admin center, or in the access lists themselves. Someone whose account has
been deleted is no longer in Graph: hand over their access by the object id the
lists show.
