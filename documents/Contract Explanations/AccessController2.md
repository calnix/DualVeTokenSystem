# AccessController: Frequency-Based Role Hierarchy Design

## Access Control Architecture

The AccessController contract establishes a role-based permission model that aligns administrative responsibilities with operational realities.

- The AccessController implements a frequency-based role hierarchy for the Moca protocol, clearly separating high-frequency operational tasks from strategic, high-impact decisions.
- This design solves a classic access control problem: requiring executive approval for routine actions slows down operations, but removing oversight increases risk.
- By mapping permissions to how often they're needed (i.e. frequency) rather than a rigid static hierarchy commonly implemented, the system enables fast, flexible execution for daily tasks, while ensuring all critical decisions must have an executive review, sign-off and deliberate approval.
- The result: efficient and agile daily operations, without executive bottlenecks or sacrificing strong governance.

>The contract embeds defense-in-depth, multi-signature checks, and global admin override, making the system both robust and resilient.

**TLDR: The system is optimized for two key factors:**
1. How frequently roles need to be updated
2. How often privileged/admin actions are performed

By separating high-frequency operations from critical governance, the architecture enables rapid day-to-day responses while maintaining strict security. This approach reduces admin overhead and signer fatigue, isolates risk through role separation, and empowers the team to act quickly—without compromising control or security.

## Key Design Principles

**The core structure is guided by operational frequency:**
- High-frequency roles (e.g., daily monitoring or epoch processing) are managed by dedicated admins for rapid, frictionless updates without delays.
- Low-frequency strategic roles (e.g., parameter updates or asset withdrawals) stay under direct global admin control, requiring explicit senior leadership approval. *[enforces thoughtful governance]*
- Dedicated admins manage high-frequency operations (e.g., monitoring, epoch processing) for speed, while global admin approval is mandatory for low-frequency, high-impact actions (e.g., parameter changes, asset withdrawals) to guarantee rigorous oversight.

- This frequency-based separation reduces administrative bottlenecks for routine operations, while concentrating authority for critical changes. 



**This creates three distinct operational layers:**
Daily Operations - Bot monitoring and epoch processing have dedicated admin teams that can rapidly add or remove operators without executive involvement
Strategic Functions - Protocol parameters, voting configuration, and treasury management require executive multi-signature approval
Emergency Controls - Asset recovery and system pauses remain available but tightly controlled


## Core Principle: Operational Frequency Drives Administrative Authority

Traditional role hierarchies create bottlenecks by requiring executive approval for all privileged operations. Our system recognizes that:

1. High-frequency operations (bot rotation, epoch processing) need dedicated admins for immediate response.
2. Strategic decisions (protocol parameters, asset management) require deliberate executive oversight.
3. Emergency functions must be available but tightly controlled.

In recognizing this, our design principle is as follows:

**Key Design Principles:**
- Frequency-based role separation: High-frequency operations get dedicated admin roles to avoid governance bottlenecks
- Operational efficiency: Daily operations proceed without constant executive approval
- Defense in depth: Multi-layered permissions with override capabilities
- Strategic control: Critical decisions remain centralized under global admin


This innovative frequency-driven approach streamlines operations by eliminating bottlenecks, while preserving robust governance. 
It empowers rapid, flexible daily operations, and ensures that critical/sensitive decisions are subject to executive sign-off.
- High-frequency operations can be executed with speed, efficiency and without delays.
- Critical changes require executive governance approvals.
- Should issues arise, global admins retain full override authority, providing a reliable failsafe.
- There is always a backstop, if something goes wrong, as the global admin can override any role.

This model delivers agility where it’s needed and security where it matters most.
You get speed where it matters, and security where it counts.

## Security Through Practical Design

Rather than over-engineering complex hierarchies, we implement defense-in-depth through:
1. **Role Isolation**: Operational compromise cannot affect strategic functions
2. **Ultimate Override**: Global admin can override any decision
3. **Appropriate Delegation**: Authority matches responsibility and frequency
4. **Multi-signature Requirements**: All roles require multi-sig approval

High-frequency roles have their own admins, so updates happen instantly—no waiting on execs. Strategic roles stay tightly held, so nothing slips through the cracks.
This aligns administrative overhead with operational needs. 

Key Design Principles:
- **Frequency-Driven Structure**: Roles that are called frequently (e.g., daily monitoring) have lightweight admins; rare roles (e.g., parameter updates) require higher-level approval.
- **Multi-Sig Integration**: All role admins use multi-signature wallets to prevent single points of failure.
- **Override Safety**: Global admin can intervene in any role for ultimate control.
- **Operational Efficiency**: Enables rapid response without constant executive involvement.
- **Least Privilege**: Limits blast radius of compromises by isolating operational and strategic functions.

This implementation is robust (multi-layered security), elegant (minimal hierarchy with clear boundaries), and efficient (matches administrative overhead to operational needs).
