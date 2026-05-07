import 'package:flutter/material.dart';

/// Reloading Guide — top-level reference screen with one tile per stage.
///
/// IMPORTANT: This is intentionally high-level reference content. It must
/// NOT contain prescriptive load data (charges, COAL targets, pressures)
/// or brand recommendations. Every detail page reinforces that the user
/// should always cross-check published manuals from the component
/// manufacturers before producing live ammunition.
class ReloadingGuideScreen extends StatelessWidget {
  const ReloadingGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Reloading Guide')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            // Top-of-screen orientation banner. Sets tone before the user
            // taps into any individual stage.
            Card(
              color: theme.colorScheme.primary.withValues(alpha: 0.10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.menu_book_outlined,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'High-Level Reference',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'A walkthrough of the eight common stages of metallic '
                      'cartridge reloading. This is reference and educational '
                      'material, not instruction. Always cross-check against '
                      'published manuals from your component manufacturers '
                      'and learn directly from a qualified handloader before '
                      'producing live ammunition.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            for (int i = 0; i < _stages.length; i++) ...[
              _StageTile(
                stageNumber: i + 1,
                stage: _stages[i],
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => _StageDetailScreen(
                        stageNumber: i + 1,
                        stage: _stages[i],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 8),
            const _IndexFooter(),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Stage tile ───────────────────────

class _StageTile extends StatelessWidget {
  const _StageTile({
    required this.stageNumber,
    required this.stage,
    required this.onTap,
  });

  final int stageNumber;
  final _Stage stage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Stage number badge.
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  '$stageNumber',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stage.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (stage.optional)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'Optional',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      stage.summary,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────── Stage detail screen ───────────────────────

class _StageDetailScreen extends StatelessWidget {
  const _StageDetailScreen({
    required this.stageNumber,
    required this.stage,
  });

  final int stageNumber;
  final _Stage stage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Stage $stageNumber: ${stage.title}'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            // Optional badge / orientation row.
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.primary.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    'Stage $stageNumber of ${_stages.length}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (stage.optional) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Optional Step',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),

            _Section(
              title: 'What This Stage Does',
              child: Text(
                stage.whatItDoes,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 12),

            _Section(
              title: 'Why It Matters',
              child: _BulletList(items: stage.whyItMatters),
            ),
            const SizedBox(height: 12),

            _Section(
              title: 'Common Tools',
              child: _BulletList(items: stage.commonTools),
            ),
            const SizedBox(height: 12),

            _Section(
              title: 'Things To Watch For',
              child: _BulletList(items: stage.thingsToWatchFor),
            ),
            const SizedBox(height: 12),

            _Section(
              title: 'Before You Move On',
              child: _BulletList(items: stage.beforeYouMoveOn),
            ),

            const SizedBox(height: 16),
            const _StageDisclaimerFooter(),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Layout primitives ───────────────────────

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _BulletList extends StatelessWidget {
  const _BulletList({required this.items});
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items) _Bullet(item),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 8, top: 2),
            child: Text('•'),
          ),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _StageDisclaimerFooter extends StatelessWidget {
  const _StageDisclaimerFooter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        'This is high-level reference. Always cross-check against published '
        'manuals from your component manufacturers (Hodgdon, Sierra, Hornady, '
        'etc.) and follow safety practices appropriate for your equipment.',
        style: theme.textTheme.bodySmall?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _IndexFooter extends StatelessWidget {
  const _IndexFooter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(
        'This guide is reference and educational material only. It is not a '
        'substitute for hands-on instruction, current published load manuals, '
        'or the safety procedures appropriate to your specific tools, '
        'components, and firearm.',
        style: theme.textTheme.bodySmall?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ─────────────────────── Stage data ───────────────────────

class _Stage {
  const _Stage({
    required this.title,
    required this.summary,
    required this.whatItDoes,
    required this.whyItMatters,
    required this.commonTools,
    required this.thingsToWatchFor,
    required this.beforeYouMoveOn,
    this.optional = false,
  });

  final String title;
  final String summary;
  final String whatItDoes;
  final List<String> whyItMatters;
  final List<String> commonTools;
  final List<String> thingsToWatchFor;
  final List<String> beforeYouMoveOn;
  final bool optional;
}

// Chronological order matters here — this is the order most metallic
// cartridge reloading workflows follow.
const List<_Stage> _stages = [
  // 1. Inspect & Sort Brass
  _Stage(
    title: 'Inspect & Sort Brass',
    summary:
        'Check each case for damage, then group by headstamp and lot before '
        'starting case prep.',
    whatItDoes:
        'Sets aside cases that are unsafe to reload and groups the remainder '
        'into batches that are likely to behave consistently together. Most '
        'reloaders also clean their brass at this stage to protect dies and '
        'make later inspection easier.',
    whyItMatters: [
      'Cases with hidden defects can fail unpredictably under pressure, which '
      'is one of the most serious safety risks in handloading.',
      'Mixing headstamps and lots introduces variation in case capacity and '
      'wall thickness, which can shift pressure and velocity for the same '
      'charge.',
      'Carbon, sand, and grit on the outside of a case can score sizing dies '
      'and damage the case mouth.',
    ],
    commonTools: [
      'A bright light and magnifier for visual inspection.',
      'A bin or tray for separating questionable cases from go-ahead cases.',
      'A tumbler — typically vibratory with corncob or walnut media, or a '
      'wet rotary tumbler with stainless pins.',
      'A media separator, towels, and a way to fully dry wet-cleaned brass.',
      'Headstamp sorting trays or simple labeled bags.',
    ],
    thingsToWatchFor: [
      'Bright rings near the case head — a classic indicator of incipient '
      'case head separation. Set those aside and do not reload them.',
      'Split necks, cracked shoulders, or dented mouths that will not iron '
      'out during sizing.',
      'Stuck primers, primer-pocket damage, or cases that have been loaded '
      'far more times than the rest of the lot.',
      'Mixed headstamps in what looked like a single batch — sort them out '
      'before going further.',
      'Wet-tumbled brass that has not fully dried before priming or '
      'reloading.',
    ],
    beforeYouMoveOn: [
      'Every case in the batch is from a known headstamp and a tracked '
      'firing-count group.',
      'Damaged or suspect cases have been removed.',
      'Cases are clean and dry, with no visible media stuck in flash holes '
      'or primer pockets.',
    ],
  ),

  // 2. Resize / Decap
  _Stage(
    title: 'Resize / Decap',
    summary:
        'Return fired brass toward chamber-ready dimensions and remove the '
        'spent primer.',
    whatItDoes:
        'Runs each case into a sizing die that brings its dimensions back '
        'toward specification and pushes the spent primer out of the pocket. '
        'Reloaders typically choose between full-length sizing, neck-only '
        'sizing, or a body-die plus mandrel approach depending on the rifle, '
        'cartridge, and goals.',
    whyItMatters: [
      'A correctly sized case chambers reliably and headspaces consistently. '
      'An undersized or overworked case shortens brass life; an oversized '
      'case can stress the case head.',
      'Decapping in this stage clears the primer pocket so it can be '
      'inspected and prepped before the next priming step.',
      'Sizing without proper lubrication on bottlenecked rifle cases can '
      'stick a case in the die and damage both the die and the case.',
    ],
    commonTools: [
      'A sizing die matched to the cartridge — full-length, neck, body, or '
      'bushing style depending on the workflow.',
      'A reloading press — single stage, turret, or progressive.',
      'Case lube and a lube pad, spray, or impregnated media. Carbide pistol '
      'dies typically allow you to skip lube; rifle dies almost always '
      'require it.',
      'A headspace comparator and bump gauge to set shoulder bump for '
      'bottleneck rifle brass.',
      'A stuck-case removal kit kept on hand in case lubrication fails.',
    ],
    thingsToWatchFor: [
      'Inadequate lube on bottleneck cases — the most common cause of stuck '
      'cases and galled die surfaces.',
      'Excess lube pooled at the shoulder, which can dent cases as the die '
      'closes (commonly called hydraulic dents).',
      'Shoulder bump that is too aggressive, working the brass excessively '
      'and shortening case life.',
      'A decapping pin that is bent, dull, or missing, which can leave '
      'primers in pockets or pierce case heads.',
      'Sized cases that still will not chamber easily in your specific '
      'rifle, indicating a die or setup issue.',
    ],
    beforeYouMoveOn: [
      'Each case has a clean, empty primer pocket.',
      'Sized cases gauge or chamber correctly in the firearm or a cartridge '
      'gauge.',
      'Excess sizing lube has been wiped or tumbled off.',
    ],
  ),

  // 3. Trim, Chamfer, Deburr
  _Stage(
    title: 'Trim, Chamfer, Deburr',
    summary:
        'Bring case length back into spec, then bevel the inside and outside '
        'of the case mouth.',
    whatItDoes:
        'Cases grow forward each time they are fired and sized, so periodic '
        'trimming returns them to a uniform length. Chamfering eases bullet '
        'entry into the case neck, and deburring removes the sharp lip left '
        'by the trimmer.',
    whyItMatters: [
      'Cases that grow longer than specification can pinch into the chamber '
      'throat and elevate pressure.',
      'Inconsistent case length contributes to inconsistent crimp and seating, '
      'which can show up as velocity and group variation.',
      'A sharp, unchamfered case mouth can shave copper from the bullet '
      'jacket during seating, hurting concentricity.',
    ],
    commonTools: [
      'A case length gauge or dial caliper to measure trim length.',
      'A trimmer — manual hand crank, lathe-style with shellholder, or '
      'powered case prep station.',
      'A chamfer / deburr tool — handheld, electric, or VLD-style for long '
      'boattail bullets.',
      'A reference number for the published trim-to length for the cartridge '
      'being loaded.',
    ],
    thingsToWatchFor: [
      'Trimming inconsistently — uneven length across the batch defeats the '
      'purpose of trimming at all.',
      'Over-aggressive chamfers that leave a knife-thin case mouth, which '
      'can crack on firing.',
      'Skipping chamfering on flat-base bullets seated into a sharp case '
      'mouth, leading to copper shavings and runout.',
      'Mixing trimmed and untrimmed cases in the same batch.',
      'Trimmer cutters that are dull or full of brass shavings, leaving '
      'rough mouth finishes.',
    ],
    beforeYouMoveOn: [
      'All cases in the batch are at or below the published trim-to length.',
      'Inside and outside of every case mouth is chamfered and deburred.',
      'No brass chips remain in the cases or on the work surface.',
    ],
  ),

  // 4. Anneal (optional)
  _Stage(
    title: 'Anneal',
    summary:
        'Optionally relieve work-hardening in the case neck and shoulder to '
        'extend brass life and stabilize neck tension.',
    optional: true,
    whatItDoes:
        'Heats the case neck and shoulder briefly to soften the brass that '
        'has been work-hardened by repeated firing and sizing. Done '
        'correctly, annealing keeps neck tension consistent across firings '
        'and significantly extends usable brass life. Done incorrectly, it '
        'can ruin a batch of brass.',
    whyItMatters: [
      'Necks become harder and springier with each firing-and-sizing cycle, '
      'which can shift neck tension and contribute to cracked necks down '
      'the line.',
      'Consistent neck tension is widely considered to help keep extreme '
      'spread and standard deviation low on precision loads.',
      'Heat must stay localized to the neck and shoulder; the case head '
      'must never be annealed because softening the head is dangerous.',
    ],
    commonTools: [
      'An induction annealing machine (such as AMP) for repeatable, '
      'time-and-power-controlled cycles.',
      'A salt bath setup with a thermometer and PPE for the molten salts.',
      'A torch flame and a rotating fixture, often with Tempilaq or similar '
      'temperature indicators to verify the heat zone.',
      'A timer or rotation mechanism so each case sees the same exposure.',
      'Heat-resistant gloves, eye protection, and a fire-safe work area.',
    ],
    thingsToWatchFor: [
      'Heating the case head — a serious safety issue. Annealing must stop '
      'at or above the shoulder.',
      'Cases that glow bright red or orange in dim light, indicating they '
      'are well past target temperature.',
      'Inconsistent dwell or distance from the flame, producing batches '
      'with very different neck tension.',
      'Salt bath spatter on damp brass — water hitting molten salts can '
      'flash to steam violently.',
      'Annealing over a flammable surface or near solvents.',
    ],
    beforeYouMoveOn: [
      'Every case in the batch has been treated identically — same '
      'machine setting, dwell, or torch position.',
      'Cases have cooled to room temperature before being handled or sized.',
      'Visual color around the neck and shoulder is consistent across the '
      'batch and the case head shows no heat discoloration.',
    ],
  ),

  // 5. Prime
  _Stage(
    title: 'Prime',
    summary:
        'Seat a fresh primer into a clean, prepared primer pocket.',
    whatItDoes:
        'Installs a new primer in each case to provide ignition for the '
        'powder charge. The goal is for every primer to seat squarely, '
        'fully below the case head, against the bottom of the pocket — but '
        'without crushing the priming compound.',
    whyItMatters: [
      'Inconsistent primer seating depth contributes to inconsistent '
      'ignition, which often shows up as elevated extreme spread.',
      'A primer left high above the case head can be a safety risk in some '
      'firearms, including the potential for slam-fires in semi-autos.',
      'Crushed or damaged primers can produce hangfires, misfires, or — '
      'rarely — out-of-battery ignition.',
    ],
    commonTools: [
      'A hand priming tool, bench priming tool, or press-mounted priming '
      'system.',
      'A primer pocket cleaner or uniformer to remove carbon and provide a '
      'consistent pocket bottom.',
      'A primer pocket swage or reamer for cases with a military-style '
      'crimp.',
      'A primer flip tray for orienting primers anvil-up.',
      'A primer seating depth gauge for batches where consistency matters.',
    ],
    thingsToWatchFor: [
      'Primers seated proud of the case head — never load such a round.',
      'Sideways, tipped, or partially seated primers, often a sign of a '
      'dirty or out-of-spec pocket.',
      'Crimped pockets that have not been swaged or reamed; a primer '
      'forced into a crimped pocket can be deformed or even ignite.',
      'Touching primers with oily hands or contaminated tools, which can '
      'deactivate the priming compound.',
      'Mixing primer types or sizes in a single batch — keep loose primers '
      'organized and labeled at all times.',
    ],
    beforeYouMoveOn: [
      'Every primer in the batch is fully seated below the case head and '
      'firmly bottomed in its pocket.',
      'No tipped, sideways, or damaged primers remain in the batch.',
      'The primer used matches what your published recipe calls for, and '
      'the lot is recorded if you track that data.',
    ],
  ),

  // 6. Charge with Powder
  _Stage(
    title: 'Charge with Powder',
    summary:
        'Drop a verified, weighed powder charge into each primed case.',
    whatItDoes:
        'Dispenses the powder charge specified by your published, '
        'cross-checked recipe into every case. This is the single most '
        'safety-critical stage of the process, because errors here scale '
        'directly to chamber pressure.',
    whyItMatters: [
      'A double charge of fast-burning pistol powder is one of the classic '
      'causes of catastrophic firearm failures. Process discipline at this '
      'step is non-negotiable.',
      'A skipped (squib) charge can lodge a bullet in the bore. Firing the '
      'next round can cause a serious failure.',
      'Even small drift in scale or thrower output stacks up across a '
      'batch and can push a load outside its safe window.',
    ],
    commonTools: [
      'A current, manufacturer-published load manual or online data source '
      'for the exact powder, primer, bullet, and cartridge being loaded.',
      'A calibrated powder scale — beam, electronic, or both. Check zero '
      'and verify against check weights.',
      'A powder thrower or electronic dispenser, with a trickler if you '
      'are weighing each charge.',
      'A loading block and good lighting so every case in the block can be '
      'visually inspected for fill level after charging.',
      'A powder-check die or similar mechanical safety on progressive '
      'presses where a missed visual check is plausible.',
    ],
    thingsToWatchFor: [
      'Any difference between the case fill level of one round and the rest '
      'of the block — investigate before seating any bullets.',
      'Powder thrown without a printed, current published recipe in front '
      'of you. Memory is not a reliable load source.',
      'Mixing powders, switching containers mid-session, or leaving an '
      'unmarked hopper of powder unattended.',
      'Static cling, drafts, or vibration that disturb electronic scale '
      'readings.',
      'Skipping the visual check on a progressive press.',
    ],
    beforeYouMoveOn: [
      'Every charged case in the loading block has the same visible fill '
      'level when checked under good light.',
      'The scale has been re-zeroed and verified at the end of the batch.',
      'Unused powder has been returned to its original, labeled container '
      'and the bench is clear of loose powder before priming or seating.',
    ],
  ),

  // 7. Seat Bullet
  _Stage(
    title: 'Seat Bullet',
    summary:
        'Press a bullet into the charged case to a consistent depth specified '
        'by your recipe.',
    whatItDoes:
        'Drives a bullet into the case neck to a target seating depth, '
        'typically expressed as overall length (COAL) or as cartridge base '
        'to ogive (CBTO). The seating depth chosen for a given cartridge, '
        'firearm, and bullet must come from a published recipe and your '
        'own measured chamber.',
    whyItMatters: [
      'Seating depth changes effective case capacity and the bullet jump to '
      'the lands, both of which influence pressure and accuracy.',
      'Inconsistent seating produces inconsistent jump and inconsistent '
      'velocity, which often shows up as vertical stringing on target.',
      'Bullets seated too deep can intrude on the powder column and elevate '
      'pressure; bullets seated too long can stick into the lands or '
      'prevent the round from chambering.',
    ],
    commonTools: [
      'A seating die appropriate for the cartridge and bullet shape, ideally '
      'with a micrometer top for repeatable adjustments.',
      'Calipers and a bullet comparator for measuring CBTO.',
      'An OAL gauge or modified case to find the distance to the lands in '
      'your specific chamber.',
      'A loading block that lets you inspect every charged case before a '
      'bullet goes on top.',
      'A concentricity gauge for checking runout if precision matters to '
      'you.',
    ],
    thingsToWatchFor: [
      'Bullet runout — visibly tilted bullets indicate die alignment, case '
      'neck, or seating issues that should be diagnosed.',
      'Bullets that seat with noticeably different effort across the batch, '
      'often a sign of inconsistent neck tension.',
      'Mixed bullet lots, base styles, or weights in a single batch when '
      'your recipe assumes one specific bullet.',
      'Adjusting the die without checking measurements after each tweak.',
      'Seating into a case that has not been visually verified for powder '
      'charge.',
    ],
    beforeYouMoveOn: [
      'Measured COAL or CBTO is consistent across the batch, within the '
      'tolerance you set for yourself.',
      'No round shows visible runout, neck damage, or copper shavings around '
      'the case mouth.',
      'Each loaded round is the result of a verified primer, verified '
      'powder charge, and verified seating measurement — in that order.',
    ],
  ),

  // 8. Final Inspection / Crimp
  _Stage(
    title: 'Final Inspection / Crimp',
    summary:
        'Optionally crimp the case mouth, then verify the finished round '
        'against a gauge or chamber.',
    optional: true,
    whatItDoes:
        'Some loads benefit from a crimp — typically a taper crimp for '
        'cartridges that headspace on the case mouth, or a roll crimp into '
        'a bullet cannelure for heavy-recoiling revolver and tube-magazine '
        'rounds. Whether or not a crimp is applied, the last step is a '
        'visual and dimensional check of every finished round.',
    whyItMatters: [
      'A taper crimp on semi-auto pistol rounds straightens the case mouth '
      'so the round headspaces correctly without over-tightening on the '
      'bullet.',
      'A roll crimp can prevent bullets from walking out of the case under '
      'recoil in revolvers and lever guns. Applied to the wrong cartridge, '
      'a roll crimp can disturb headspace or buckle the case.',
      'A final gauge check catches outliers — long rounds, oversized bases, '
      'or rounds that escaped earlier inspections — before they reach a '
      'firearm.',
    ],
    commonTools: [
      'A separate taper or roll crimp die for a dedicated crimp step, '
      'instead of crimping while seating.',
      'A cartridge gauge or chamber checker for the cartridge being loaded.',
      'Calipers for spot-checking COAL, base diameter, and crimp diameter.',
      'A magnifier and bright light for inspecting case mouths and primer '
      'seating one last time.',
      'Labeled storage — an ammo box or boxes annotated with components, '
      'powder, charge, COAL, primer, and date for traceability.',
    ],
    thingsToWatchFor: [
      'Applying a roll crimp to a cartridge that headspaces on the case '
      'mouth — this can change headspace and lead to misfeeds or pressure '
      'issues.',
      'Crimping non-cannelured bullets so hard that the bullet jacket is '
      'visibly deformed.',
      'Rounds that fail to drop fully into a cartridge gauge — set them '
      'aside and diagnose rather than forcing them.',
      'Skipping case-by-case inspection because the batch felt routine.',
      'Storing finished ammunition without a clear label tying it back to '
      'the recipe used.',
    ],
    beforeYouMoveOn: [
      'Every finished round drops freely into the cartridge gauge or the '
      'firearm\'s chamber when checked.',
      'Crimp (if applied) is uniform across the batch and matches the '
      'intent of the recipe.',
      'The completed batch is stored in a labeled box with components, '
      'charge, COAL, primer, and date recorded so the load can be '
      'reproduced or investigated later.',
    ],
  ),
];
