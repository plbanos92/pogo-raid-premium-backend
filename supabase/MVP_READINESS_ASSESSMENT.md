# Supabase Backend MVP Readiness Assessment

## Scope Reviewed
- Folder reviewed: supabase/
- Present: schema migrations, hardening migration, transactional RPC migration, local config, seed, SQL smoke tests, and CI workflow.

## Verdict
- MVP trial readiness: Yes.
- Production-grade MVP readiness: Nearly there, but still missing a few operational controls.

## What Is Already Good
- Core domain model is in place (profiles, raids, queues, subscriptions, confirmations, activity logs).
- Referential integrity, constraints, and updated_at triggers are in place.
- RLS policies now cover all current tables.
- Transaction-safe RPCs exist for queue join, host invite-next, and host status update.
- Local reproducibility exists via config.toml + seed.sql.
- CI now validates Supabase setup and runs SQL smoke checks.

## Remaining Gaps Before Calling It Production-Grade

### 1) API Surface and Product Flows
- RPC coverage is good for core queue flow, but not complete for all lifecycle actions (for example cancel raid, reopen queue, bulk host operations).
- No Edge Functions yet for external webhook/payment/provider integrations.

Impact:
- Core app works for MVP, but integrations and non-core paths are still manual.

### 2) Security and Governance
- No explicit security runbook for key rotation, privileged access, or incident procedures.
- No formal policy matrix document mapping endpoint/function to role expectations.

Impact:
- Security posture depends on tribal knowledge.

### 3) Operations and Observability
- CI smoke tests exist, but no production monitoring/alerts/runbooks are committed here.
- No backup/restore drill documentation in repository.

Impact:
- Issues may be detected later than ideal in production.

### 4) Data Lifecycle
- No retention/archive jobs yet for stale raids and old activity logs.

Impact:
- Long-term data growth could affect costs and query performance.

## MVP Deployment Decision
- If the goal is to start using APIs now for CRUD and queue/host core flows, this backend is complete enough for MVP deployment.
- If the goal is production hardening for scale/compliance, complete the remaining controls above next.

## Recommended Next Steps (Post-Deploy)
1. Add a security/operations runbook and policy matrix document.
2. Add retention jobs for historical data cleanup.
3. Add monitoring and alerting playbooks for database/API health.
4. Expand RPC/Edge Function coverage for full operational lifecycle and external integrations.
