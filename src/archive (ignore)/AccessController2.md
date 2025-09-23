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

By separating high-frequency operations from critical governance, the architecture enables rapid day-to-day responses while maintaining strict security.
This approach reduces admin overhead and signer fatigue, isolates risk through role separation, and empowers the team to act quickly—without compromising control or security.

## Key Design Principles

This architecture is built on a simple, powerful principle: align authority with operational frequency to maximize both agility and security.

**Frequency-Driven Authority:** High-frequency roles—like daily monitoring or epoch processing—are managed by dedicated admin teams, enabling rapid updates and seamless daily operations without executive bottlenecks. In contrast, low-frequency, high-impact roles—such as protocol parameter changes or asset withdrawals—require direct global admin approval, ensuring deliberate, thoughtful governance.

**Operational Efficiency & Security:** By separating routine operations from strategic decisions, the system eliminates unnecessary delays and reduces admin fatigue. Least-privilege access and strict role isolation limit the blast radius of any compromise. Multi-signature wallets are required for all roles, removing single points of failure and distributing control.

**Override & Resilience:** The global admin always retains ultimate override authority, providing a robust failsafe for emergencies or unexpected events.

**Simplicity & Scalability:** The hierarchy is minimal and clear, with immutable role identifiers and explicit, non-overlapping permissions. This makes the system easy to maintain and adapt as the protocol grows.

**Three Operational Layers:**
1. **Daily Operations:** Bot monitoring and epoch processing, managed by dedicated admin teams for fast, flexible response.
2. **Strategic Functions:** Protocol parameters, voting configuration, and treasury management, all requiring executive multi-signature approval.
3. **Emergency Controls:** Asset recovery and system pauses, tightly controlled and always available to the global admin.

**Security by Design:**  
- Operational and strategic roles are strictly segregated.  
- All admin actions require multi-signature approval.  
- The global admin can override any role or action.  
- Each role’s permissions are explicit and limited, with no overlap.

This frequency-based, least-privilege model streamlines daily operations, concentrates authority for critical changes, and delivers a system that is both robust against threats and highly adaptable to evolving needs.


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
