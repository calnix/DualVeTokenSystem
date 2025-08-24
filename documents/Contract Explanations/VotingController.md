# VotingControllers

Do we need the whitelist flag in pool struct?
- just create, remove, activate/deactivate is fine



## delegate fees

problem on delegate fees:
- delegate changes fees in epoch N
- user claims rewards from his delegated votes, for epoch N-2
- user would be paying fees as per the latest fee update
- essentially, fees are a static reference. they aren't indexed on an epoch basis.