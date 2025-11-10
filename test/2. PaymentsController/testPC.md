PaymentsController

deploy
---------------
admin create subsidy tiers
---------------
create profiles
- issuer
- verifier

---------------
issuer1 creates schema
- schema 1

issuer 2 creates schema
- schema 2

issuer 3 creates schema
- schema 3
- zero fee
---------------
verifier deposits USD8
- can deposit [frm asset addr]
- can withdraw
---------------
deductBalance: verifier pays
- all the negative checks
- till final positive matching sig check
---------------
verifier changes signerAddress
- deductBalance should work w/ new sig.
---------------
issuer decreases fee
- impact instant
- test deductBalance
---------------
issuer increases fee
- impact delayed
- warp
- test deduct Balance
---------------
deductBalanceZeroFees
- schema 3
---------------
subsidies: verifier stakes moca
- deductBalance should book subsidy
- test for each tier
- unstake moca() ----> not yet i 🤔 
---------------
issuer can claim fees✅ 
---------------
update AssetAddress: issuer 
- issuer can claim MOCA on old address ✅ 
- issuer can claim from new address ✅ 
---------------
update AssetAddress: verifier ✅
- withdraw USD8 on old address 
- withdraw remainder from new address✅
---------------
updateAdminAddress✅
- both issuer and verifier✅
- check they can execute config actions frm new ✅
- check they cannot execute config actions frm old ✅
---------------
Admin fns: updateProtocolFeePercentage ✅
- deductBalance books correctly✅
---------------
Admin fns: updateVotingFeePercentage✅
- deductBalance books correctly✅
---------------
Admin fns: updateVerifierSubsidyPercentages✅
- deductBalance books new subsidy correctly✅
---------------
Admin fns: updateFeeIncreaseDelayPeriod✅
- issuer increases fee; new delay period logged✅
- deductBalance called after changed✅
---------------
Admin fns: updatePoolId✅ [earlier to check book subsidies]
- state reflected correctly

------------------------------
Admin: withdraw fns
------------------------------
Admin: risk fns
- emergencyExitVerifiers
- emergencyExitIssuers


        paymentsController.updateVerifierSubsidyPercentages(10 ether, 1000);
        // Second tier
        paymentsController.updateVerifierSubsidyPercentages(20 ether, 2000);       
        // Third tier
        paymentsController.updateVerifierSubsidyPercentages(30 ether, 3000);
