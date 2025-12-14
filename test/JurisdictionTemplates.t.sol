// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/JurisdictionTemplates.sol";

contract JurisdictionTemplatesTest is Test {
    using JurisdictionTemplates for Jurisdiction;

    function test_USChapter11_Thresholds() public pure {
        JurisdictionParams memory p = Jurisdiction.US_CHAPTER_11.get();

        // Verify name
        assertEq(p.name, "US Chapter 11");

        // Verify voting thresholds (66.67% value + 50% headcount, dual test)
        assertEq(p.voting.approvalThresholdBps, 6667);
        assertEq(p.voting.approvalHeadcountBps, 5001);
        assertEq(p.voting.vetoThresholdBps, 3334);
        assertEq(p.voting.vetoQuorumBps, 500);
        assertTrue(p.voting.requiresDualTest);

        // Verify timeframes
        assertEq(p.timeframes.redemptionBreachPeriod, 7 days);
        assertEq(p.timeframes.settlementPeriod, 30 days);
        assertEq(p.timeframes.votingPeriod, 25 days);
        assertEq(p.timeframes.extensionPeriod, 15 days);
        assertEq(p.timeframes.challengePeriod, 14 days);

        // Verify rules
        assertTrue(p.rules.absolutePriorityRule);
        assertFalse(p.rules.parPassuOption);
        assertTrue(p.rules.transferLockOnTrigger);
        assertEq(p.rules.interestRateBps, 500);
    }

    function test_USChapter7_NoVoting() public pure {
        JurisdictionParams memory p = Jurisdiction.US_CHAPTER_7.get();

        assertEq(p.name, "US Chapter 7");

        // Chapter 7 is liquidation - no voting required
        assertEq(p.voting.approvalThresholdBps, 0);
        assertEq(p.voting.approvalHeadcountBps, 0);
        assertEq(p.voting.vetoThresholdBps, 0);
        assertFalse(p.voting.requiresDualTest);

        // Direct to liquidation
        assertEq(p.timeframes.settlementPeriod, 0);
        assertEq(p.timeframes.votingPeriod, 0);

        // Strict absolute priority
        assertTrue(p.rules.absolutePriorityRule);
        assertFalse(p.rules.parPassuOption);
    }

    function test_UKCVA_Thresholds() public pure {
        JurisdictionParams memory p = Jurisdiction.UK_CVA.get();

        assertEq(p.name, "UK CVA");

        // UK CVA: 75% by value, 50% excluding connected parties
        assertEq(p.voting.approvalThresholdBps, 7500);
        assertEq(p.voting.approvalHeadcountBps, 5001);
        assertTrue(p.voting.requiresDualTest);

        // UK uses 28-day periods
        assertEq(p.timeframes.settlementPeriod, 28 days);
        assertEq(p.timeframes.votingPeriod, 28 days);
        assertEq(p.timeframes.challengePeriod, 28 days);

        // CVA can modify priority
        assertFalse(p.rules.absolutePriorityRule);
        assertTrue(p.rules.parPassuOption);

        // UK judgment rate ~8%
        assertEq(p.rules.interestRateBps, 800);
    }

    function test_GermanyInsO_Thresholds() public pure {
        JurisdictionParams memory p = Jurisdiction.GERMANY_INSOLVENCY.get();

        assertEq(p.name, "Germany InsO");

        // Germany InsO: >50% by value AND >50% by number
        assertEq(p.voting.approvalThresholdBps, 5001);
        assertEq(p.voting.approvalHeadcountBps, 5001);
        assertTrue(p.voting.requiresDualTest);

        // 50% blocking
        assertEq(p.voting.vetoThresholdBps, 5000);

        // 3-week periods
        assertEq(p.timeframes.settlementPeriod, 21 days);
        assertEq(p.timeframes.votingPeriod, 21 days);
    }

    function test_GermanyStaRUG_Thresholds() public pure {
        JurisdictionParams memory p = Jurisdiction.GERMANY_STARUG.get();

        assertEq(p.name, "Germany StaRUG");

        // StaRUG: 75% by value only (no headcount)
        assertEq(p.voting.approvalThresholdBps, 7500);
        assertEq(p.voting.approvalHeadcountBps, 0);
        assertFalse(p.voting.requiresDualTest);

        // 25% blocking
        assertEq(p.voting.vetoThresholdBps, 2500);

        // Required for cramdown
        assertTrue(p.rules.absolutePriorityRule);
    }

    function test_SingaporeIRDA_Thresholds() public pure {
        JurisdictionParams memory p = Jurisdiction.SINGAPORE_IRDA.get();

        assertEq(p.name, "Singapore IRDA");

        // IRDA: 75% by value AND >50% by number
        assertEq(p.voting.approvalThresholdBps, 7500);
        assertEq(p.voting.approvalHeadcountBps, 5001);
        assertTrue(p.voting.requiresDualTest);

        // Singapore allows longer extensions
        assertEq(p.timeframes.extensionPeriod, 30 days);

        // Singapore default rate 5.35%
        assertEq(p.rules.interestRateBps, 535);
    }

    function test_CaymanLiquidation_Thresholds() public pure {
        JurisdictionParams memory p = Jurisdiction.CAYMAN_LIQUIDATION.get();

        assertEq(p.name, "Cayman Liquidation");

        // Cayman: 75% for special resolution, value only
        assertEq(p.voting.approvalThresholdBps, 7500);
        assertEq(p.voting.approvalHeadcountBps, 0);
        assertFalse(p.voting.requiresDualTest);

        // Pari passu common in Cayman
        assertTrue(p.rules.parPassuOption);
    }

    function test_DeFiStandard_BalancedApproach() public pure {
        JurisdictionParams memory p = Jurisdiction.DEFI_STANDARD.get();

        assertEq(p.name, "DeFi Standard");

        // US-style thresholds (66.67% + 50%)
        assertEq(p.voting.approvalThresholdBps, 6667);
        assertEq(p.voting.approvalHeadcountBps, 5001);
        assertTrue(p.voting.requiresDualTest);

        // Faster timeframes for DeFi
        assertEq(p.timeframes.votingPeriod, 14 days);
        assertEq(p.timeframes.extensionPeriod, 7 days);
        assertEq(p.timeframes.challengePeriod, 7 days);

        // Both priority options available
        assertTrue(p.rules.absolutePriorityRule);
        assertTrue(p.rules.parPassuOption);
    }

    function test_HelperFunctions() public pure {
        // Test getName
        assertEq(Jurisdiction.US_CHAPTER_11.getName(), "US Chapter 11");
        assertEq(Jurisdiction.DEFI_STANDARD.getName(), "DeFi Standard");

        // Test requiresDualTest
        assertTrue(Jurisdiction.US_CHAPTER_11.requiresDualTest());
        assertFalse(Jurisdiction.GERMANY_STARUG.requiresDualTest());

        // Test getApprovalThreshold
        assertEq(Jurisdiction.UK_CVA.getApprovalThreshold(), 7500);
        assertEq(Jurisdiction.US_CHAPTER_7.getApprovalThreshold(), 0);

        // Test usesAbsolutePriority
        assertTrue(Jurisdiction.US_CHAPTER_11.usesAbsolutePriority());
        assertFalse(Jurisdiction.UK_CVA.usesAbsolutePriority());
    }

    function test_GetVotingThresholds() public pure {
        VotingThresholds memory v = Jurisdiction.SINGAPORE_IRDA.getVotingThresholds();

        assertEq(v.approvalThresholdBps, 7500);
        assertEq(v.approvalHeadcountBps, 5001);
        assertEq(v.vetoThresholdBps, 2500);
        assertEq(v.vetoQuorumBps, 500);
        assertTrue(v.requiresDualTest);
    }

    function test_GetTimeframes() public pure {
        InsolvencyTimeframes memory t = Jurisdiction.UK_CVA.getTimeframes();

        assertEq(t.redemptionBreachPeriod, 7 days);
        assertEq(t.settlementPeriod, 28 days);
        assertEq(t.votingPeriod, 28 days);
        assertEq(t.extensionPeriod, 14 days);
        assertEq(t.challengePeriod, 28 days);
    }

    function test_GetRules() public pure {
        InsolvencyRules memory r = Jurisdiction.CAYMAN_LIQUIDATION.getRules();

        assertTrue(r.absolutePriorityRule);
        assertTrue(r.parPassuOption);
        assertTrue(r.transferLockOnTrigger);
        assertEq(r.interestRateBps, 500);
    }

    function test_AllJurisdictions_HaveRedemptionBreachPeriod() public pure {
        // All jurisdictions should have 7-day redemption breach period
        assertEq(Jurisdiction.US_CHAPTER_11.get().timeframes.redemptionBreachPeriod, 7 days);
        assertEq(Jurisdiction.US_CHAPTER_7.get().timeframes.redemptionBreachPeriod, 7 days);
        assertEq(Jurisdiction.UK_CVA.get().timeframes.redemptionBreachPeriod, 7 days);
        assertEq(Jurisdiction.UK_ADMINISTRATION.get().timeframes.redemptionBreachPeriod, 7 days);
        assertEq(Jurisdiction.GERMANY_INSOLVENCY.get().timeframes.redemptionBreachPeriod, 7 days);
        assertEq(Jurisdiction.GERMANY_STARUG.get().timeframes.redemptionBreachPeriod, 7 days);
        assertEq(Jurisdiction.SINGAPORE_IRDA.get().timeframes.redemptionBreachPeriod, 7 days);
        assertEq(Jurisdiction.CAYMAN_LIQUIDATION.get().timeframes.redemptionBreachPeriod, 7 days);
        assertEq(Jurisdiction.DEFI_STANDARD.get().timeframes.redemptionBreachPeriod, 7 days);
    }

    function test_AllJurisdictions_HaveTransferLock() public pure {
        // All jurisdictions should lock transfers on trigger
        assertTrue(Jurisdiction.US_CHAPTER_11.get().rules.transferLockOnTrigger);
        assertTrue(Jurisdiction.US_CHAPTER_7.get().rules.transferLockOnTrigger);
        assertTrue(Jurisdiction.UK_CVA.get().rules.transferLockOnTrigger);
        assertTrue(Jurisdiction.UK_ADMINISTRATION.get().rules.transferLockOnTrigger);
        assertTrue(Jurisdiction.GERMANY_INSOLVENCY.get().rules.transferLockOnTrigger);
        assertTrue(Jurisdiction.GERMANY_STARUG.get().rules.transferLockOnTrigger);
        assertTrue(Jurisdiction.SINGAPORE_IRDA.get().rules.transferLockOnTrigger);
        assertTrue(Jurisdiction.CAYMAN_LIQUIDATION.get().rules.transferLockOnTrigger);
        assertTrue(Jurisdiction.DEFI_STANDARD.get().rules.transferLockOnTrigger);
    }

    function test_DualTestJurisdictions() public pure {
        // Jurisdictions that require BOTH value AND headcount
        assertTrue(Jurisdiction.US_CHAPTER_11.get().voting.requiresDualTest);
        assertTrue(Jurisdiction.UK_CVA.get().voting.requiresDualTest);
        assertTrue(Jurisdiction.GERMANY_INSOLVENCY.get().voting.requiresDualTest);
        assertTrue(Jurisdiction.SINGAPORE_IRDA.get().voting.requiresDualTest);
        assertTrue(Jurisdiction.DEFI_STANDARD.get().voting.requiresDualTest);

        // Jurisdictions that only require value
        assertFalse(Jurisdiction.US_CHAPTER_7.get().voting.requiresDualTest);
        assertFalse(Jurisdiction.UK_ADMINISTRATION.get().voting.requiresDualTest);
        assertFalse(Jurisdiction.GERMANY_STARUG.get().voting.requiresDualTest);
        assertFalse(Jurisdiction.CAYMAN_LIQUIDATION.get().voting.requiresDualTest);
    }
}
