# ve [Aerodrome]


# createLockFor

1. floor duration: to be nearest largest multiple of weeks
- i.e 2.8 weeks -> 2 weeks
- user expresses duration as seconds
- user can only lock for X weeks  [X is a integer]

2. get and mint the next tokenId to user

## 3. depositFor(_tokenId, _value, unlockTime, _locked[_token], CREATE_LOCK_TYPE)
- unlockTime is a multiple of weeks
- _locked[_token] is an empty struct LockedBalance{amount,end}

totalSupply is incremented.

newLock: by duplicating oldLock 
- both new and old locks are empty structs.

Update new lock and Push to Storage
- increment newLocked.amount by incoming lockAmount
- set .endTime to _unlockTime
- push to _locked[] mapping

TransferFrom: moca tokens for the new lock.

## 4. _checkpoint(tokenId, oldLocked, newlocked)
- oldLock is empty LockedBalance{amount,end} struct
- newLock is updated with new lock's amount and endTime

Init 
- 2 UserPoints: `uold, uNew`
- 2 decay slopes: `oldDslope`, `newDslope`
- Cache current `epoch`

### 4.1 Init UserPoints structs, `uold, uNew`: `if(tokenId != 0)`: 

> UserPoint{bias, slope, ts, blk, permanent}

1. ignore `uold`, old UserPoint: 0 struct
> user's first lock. so oldLock does not exist

2. create `nOld`, new UserPoint for the incoming lock
 .`slope = amount / MAXTIME`
 .`bias = slope * lockDuration`

*Is a UserPoint basically a lock?*
*Maybe a Lock is 2 parts: LockedBalance{amt,end} and UserPoint{slope,bias,ts,blk}*

### 4.2 Get global scheduled slopeChanges 

1st lock. no prior slope changes were booked; slopeChanges[] is a 0 mapping.
`oldDslope = newDslope = 0`.

```bash
oldDslope = slopeChanges[0]  
newDslope = slopeChanges[1,063,072,000]
```
> oldSlop is non-zero if there were prior locks

### 4.3 Get latest Global Checkpoint [last index, to start updating from]

if 1st call to contract: init new globalPoint
else: get latest globalPoint via `_pointHistory[epoch]`

```
.bias & .slope = 0
.ts = block.timestamp
.blk = block.number
```

### 4.4 get lastUpdateTimestamp [lastCheckpoint, starting point for update]

By referencing lastPoint.ts:

- if 1st call: `lastCheckPoint = block.timestamp` 
- else: `lastCheckPoint = someTimePrior` 

have to update global slopes,supply,etc by iterating through past checkpoints to `now`.
so need the lastUpdateTimestamp, as starting point

### 4.5 duplicate latest Global Checkpoint[?]
create dupl copy of 4.3

### 4.6 blockSlope [skip]
blockSlope = 0 (no prior history)

### 4.5 Update Global checkpoint: iterate thru slopeChanges[]
From lastPoint, we iterate thru slopeChanges to get the new lastPoint [GlobalPoint]

```
`t_i` is nextTimestamp
- nextTimestamp is `lastCheckpoint + 1 WEEK`; advance by a week
- get the incoming slopeChanges[nextTimestamp]
- from past move to now
```

For 1st create: `t_i = block.timestamp `
- do not get slopeChanges, since there are slopeChanges in the past
- hence the flooring of t_i to now at max, cannot go into future

Calculate accruedDecay from lastCheckPoint to `t_i`[nextCheckPoint]
- on first call, there is no prior check point
- slope is 0: 0*0 [lastpoint.slope * (now - now)]
- bias is 0: since `d_slope` is 0

**slope and bias remain 0. There was nothing prior to book**

<iterated thru slopeChanges: updated global checkpoint for now: lastPoint>
<break out of for loop>

### 4.6 Apply User Changes to Global Point

lastPoint.slope = uNew.slope
lastPoint.bias = uNew.bias
- uOld is 0 struct

<Alice’s lock adds 50 to bias and 7.925 × 10⁻⁷ to global slope>

### 4.6 Save Global Point: push to storage

`_pointHistory[1] = lastPoint`

- first global checkpoint recorded
- epoch = 1, incremented in loop

### 4.7 Schedule Slope Changes and Save User Checkpoint

1. Schedule Slope Changes

`slopeChanges[_newLocked.endTime] = newDslope;`

`newDslope` is the user's UserPOint{bias,slope,ts,blk}
- calculated this at the start of checkPoint
- newDslope.

2. Save User Checkpoint




# Questions

1. tokenId starts at 1
- so when do we skip the `if(tokenId != 0)` in checkpoint?

2. userPointEpoch[uint256 lock/tokenId -> uint256 index]

- for a specific lock, return the index for its Point[] array [for _userpointHistory]
> tokenId is lockId
> userPointHistory is just lockPointHistory for a specific lock. Point{bias,slope}

*why does userEpoch start frm 0? just convenience so can ++userEpoch*

*since userEpoch starts at 1, userPointHistory[lockId][index]*

userPointHistory[lockId][index] -> userPointHistory[lockId][userEpoch]

userPointHistory[1][1] = uNew = Point{bias,slope, lastUpdate}
lockPointHistory[lockId:1][index:1] = uNew = Point{bias,slope, lastUpdate}

is means that for locks, their Lock[] array [history tracking], the first element is stored to index:1.
not index:0
nothing gets stored to index:0.

**yes something about binary search for balanceOfAt**

### 3. epochs and weekly buckets

- the first txn createLock decides the starting point, t0.
- from that point, contract operates in weekly cycles
- not calendar weeks

is this correct?

> This value represents the start of the week containing lastCheckpoint (1,006,912,000), rounded down to the nearest multiple of WEEK (604,800 seconds).

### 4. supply is principal deposits? 

- seems like, since you add value to supple in _depositFOr
- so, that is the ve totalSupply - confirm it has nothing to with globl var. `supply`

## Scenario

1. create
2. create another
3. redeem early
4. extend