# Overview


## Time Anchor

    cos' we calculate bias from T0 to Now
    the starting anchor point for the contract is T0
    meaning, 
    - the first week start is T0 
    - the second week start is T0+1 week
    - the third week start is T0+2 weeks
    - etc.

    so on user's passing expiry
    - expiry is specified timestamp representing endTime; not duration
    - expiry is sanitized isValidTime: expiry % Constants.WEEK == 0
    - this ensures that the endTime lies on a week boundary; not inbtw
    - 

    this would not be the case if our starting point was some arbitrary time; not T0
    as the weekly count would start at TX, and time checks would have to be done with respect to TX

## User Aggregation

        // book all prior checkpoints | veGlobal not stored
        //DataTypes.VeBalance memory veGlobal_ = _updateGlobal();

        // update user aggregated
        /**
            treat the user as 'global'. 
            must do prior updates to bring user's bias and slope to current week. [_updateGlobal]
            then add new position to user's aggregated veBalance
            then schedule slope changes for the new position

            1. bias
            2. slope
            3. scheduled slope changes
            
            note:
            could possibly skip the prior updates, and just add the new position to user's veBalance + schedule changes
            then have view fn balanceOf do the prior updates. saves gas
         */
        //DataTypes.VeBalance memory veUser = _updateUser(msg.sender);

## Total supply / Total Voting Power

### For historical searches

we are able to obtain the total ve supply or voting power at a specific weekly boundary.
We do so by referencing, the mapping `totalSupplyAt[wTime]`, and passing the timestamp of the weekly boundary.
If we past a timestamp that is not a valid weekly boundary, it will return 0.

We are unable to obtain or interpolate total supply for an arbitrary time in the past, that does not lie on a weekly boundary.
This is because the mapping `totalSupplyAt[wTime]` stores snapshots of supply values, not `VeBalance{bias, slope}` structs.

If we had chosen to store snapshots of structs, it would be possible. However, there does not appear to be a need for it, and is disregarded. 

### For forward-projection

Refer to the state variable `veGlobal`, and calculate the forward decay accordingly.
This is forward decay based on current state.

`lastUpdatedTimestamp` reflects when veGlobal was last updated.

*note: what about forward decay and accounting for incoming slopeChanges?*
