// The flexible schedule builder is injected as an additive UI layer so the
// existing KCP screens and visual structure remain untouched.

if (!document.querySelector('link[href="./generic-schedule.css"]')) {
  const stylesheet = document.createElement('link')
  stylesheet.rel = 'stylesheet'
  stylesheet.href = './generic-schedule.css'
  document.head.appendChild(stylesheet)
}

if (!document.getElementById('genericGroupDialog')) {
  document.body.insertAdjacentHTML('beforeend', `
    <dialog id="genericGroupDialog" class="modal">
      <form id="genericGroupForm" method="dialog" class="dialog-form">
        <div class="dialog-title">
          <div><span class="eyebrow">NEW PRIVATE GROUP</span><h2>Create carpool group</h2></div>
          <button class="close-button" value="cancel" formmethod="dialog" aria-label="Close">×</button>
        </div>
        <p class="schedule-builder-intro">You become the group owner. After creating the group, KCP helps you set the weekly rides.</p>
        <label>Group name
          <input id="genericGroupName" required maxlength="120" placeholder="Music class carpool">
        </label>
        <label>Group type
          <select id="genericGroupType" required>
            <option value="school">School</option>
            <option value="music">Music</option>
            <option value="club">Club</option>
            <option value="training">Training</option>
            <option value="gymnastics">Gymnastics</option>
            <option value="tennis">Tennis</option>
            <option value="other">Other</option>
          </select>
        </label>
        <label>Destination or activity
          <input id="genericDestination" required maxlength="160" placeholder="School, studio, club, court or venue">
        </label>
        <label>Term or season <span class="optional">optional</span>
          <input id="genericTerm" maxlength="80" placeholder="2026–27, Fall season, ongoing">
        </label>
        <label>Timezone
          <select id="genericTimezone">
            <option value="America/Phoenix">Phoenix / Arizona</option>
            <option value="America/Los_Angeles">Pacific</option>
            <option value="America/Denver">Mountain</option>
            <option value="America/Chicago">Central</option>
            <option value="America/New_York">Eastern</option>
            <option value="UTC">UTC</option>
          </select>
        </label>
        <label>Child or rider name
          <input id="genericChildName" required maxlength="80" placeholder="Child name">
        </label>
        <label>Grade or level <span class="optional">optional</span>
          <input id="genericGradeLevel" maxlength="40" placeholder="5, Beginner, Level 2">
        </label>
        <section class="schedule-step-card">
          <div class="schedule-step-head">
            <div class="schedule-step-number">+</div>
            <div><span class="eyebrow">OTHER FAMILIES</span><h3>Invite drivers and add known riders</h3></div>
          </div>
          <p class="meta">Add the details you know. KCP emails each driver a private Accept or Decline link. You can check the schedule while replies are pending.</p>
          <div id="groupDriverInvites" class="schedule-sessions-list"></div>
          <button id="addGroupDriverInvite" class="secondary-button" type="button">+ Add another driver</button>
        </section>
        <button class="primary-button" type="submit">Create group and set rides</button>
      </form>
    </dialog>
  `)
}

if (!document.getElementById('scheduleBuilderDialog')) {
  document.body.insertAdjacentHTML('beforeend', `
    <dialog id="scheduleBuilderDialog" class="modal schedule-builder-modal">
      <form id="scheduleBuilderForm" method="dialog" class="schedule-builder-form">
        <div class="dialog-title">
          <div class="schedule-dialog-navigation">
            <button id="scheduleTopBack" class="schedule-dialog-back" data-action="schedule-step-back" type="button" aria-label="Go back"><span aria-hidden="true">‹</span><strong>Back</strong></button>
            <div><span class="eyebrow">RIDE SCHEDULE</span><h2>Set weekly rides</h2></div>
          </div>
          <button class="close-button" value="cancel" formmethod="dialog" aria-label="Close">×</button>
        </div>
        <p class="schedule-builder-intro">Choose the days and times, decide how driving is shared, check the rides, then make the schedule live.</p>

        <section class="schedule-step-card">
          <div class="schedule-step-head">
            <div class="schedule-step-number">1</div>
            <div><span class="eyebrow">DATES</span><h3>Name and date range</h3></div>
          </div>
          <div class="schedule-basic-grid">
            <label class="full-width">Schedule name
              <input id="schedulePlanName" required maxlength="120" value="Weekly schedule">
            </label>
            <label>Starts
              <input id="scheduleStartsOn" required type="date">
            </label>
            <label>Ends
              <input id="scheduleEndsOn" required type="date">
            </label>
            <label>Drop-off label
              <input id="scheduleOutboundLabel" required maxlength="60" value="Drop-off">
            </label>
            <label>Pickup label
              <input id="scheduleReturnLabel" required maxlength="60" value="Pickup">
            </label>
            <label class="full-width">Mark a ride complete after
              <select id="scheduleAutoComplete">
                <option value="15">15 minutes</option>
                <option value="30">30 minutes</option>
                <option value="45">45 minutes</option>
                <option value="60" selected>60 minutes</option>
                <option value="90">90 minutes</option>
                <option value="120">2 hours</option>
              </select>
            </label>
          </div>
        </section>

        <section class="schedule-step-card">
          <div class="schedule-step-head">
            <div class="schedule-step-number">2</div>
            <div><span class="eyebrow">WHEN</span><h3>Days and ride times</h3></div>
          </div>
          <div id="scheduleSessionsList" class="schedule-sessions-list"></div>
          <button class="secondary-button" data-action="add-schedule-session" type="button">+ Add another day or time</button>
        </section>

        <section class="schedule-step-card">
          <div class="schedule-step-head">
            <div class="schedule-step-number">3</div>
            <div><span class="eyebrow">WHO</span><h3>Choose drivers</h3></div>
          </div>
          <label>How should driving be shared?
            <select id="scheduleStrategy">
              <option value="fixed">Use the same driver</option>
              <option value="round_robin_trip">Take turns for each ride</option>
              <option value="round_robin_day">Take turns by day</option>
              <option value="round_robin_week">Take turns by week</option>
              <option value="balanced">Share rides as evenly as possible</option>
              <option value="manual">Choose drivers later</option>
            </select>
          </label>
          <div id="scheduleStrategyHelp" class="strategy-help"></div>
          <p id="scheduleWeeklyHint" class="weekly-bundle-hint hidden">One selected parent receives every configured day and both ride legs for the assigned week. The next week moves to the next parent.</p>
          <div class="schedule-label-grid" style="margin-top:12px">
            <label>Start the driver order on
              <input id="scheduleAnchorDate" type="date">
            </label>
            <label>When a week has no rides
              <select id="scheduleCycleBehavior">
                <option value="calendar">Keep the weekly turn order</option>
                <option value="occurrence">Move on only after a week with rides</option>
              </select>
            </label>
            <label id="scheduleFixedParticipantRow" class="full-width">Driver
              <select id="scheduleFixedParticipant"></select>
            </label>
          </div>
          <h4 style="margin:16px 0 8px">Driver order</h4>
          <div id="scheduleParticipantsList" class="rotation-list"></div>
        </section>

        <section class="schedule-step-card">
          <div class="schedule-step-head">
            <div class="schedule-step-number">4</div>
            <div><span class="eyebrow">CHECK</span><h3>Check rides before sharing</h3></div>
          </div>
          <div id="schedulePreview" class="schedule-preview"></div>
        </section>

        <div class="schedule-builder-actions">
          <button class="secondary-button" type="submit">Check schedule</button>
          <button id="publishSchedulePlan" class="primary-button" type="button">Make schedule live</button>
        </div>
      </form>
    </dialog>
  `)
}
