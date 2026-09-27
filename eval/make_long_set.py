#!/usr/bin/env python3
"""Writes eval/long/emails.jsonl: email/message-length texts with known errors.

Each case has the original text and the minimal reference correction
(expect: null = already correct, must stay unchanged). Kept as Python so the
multi-line texts stay readable; rerun after editing.
"""
import json, pathlib

CASES = []


def case(tone, text, fixes, note):
    """fixes: list of (wrong, right) substrings, applied once each, in order."""
    ref = text
    for wrong, right in fixes:
        assert ref.count(wrong) == 1, f"{note}: {wrong!r} must occur exactly once"
        ref = ref.replace(wrong, right)
    CASES.append({"text": text, "tone": tone, "expect": [ref] if fixes else None,
                  "errors": [f"{w} → {r}" for w, r in fixes], "note": note})


case("formal", """Hi Sarah,

I hope you're doing well. I wanted to give you a quick update on the migration project. The team finished moving the billing service to the new cluster last week, and everything has been running smoothly since than.

There is still a few things we need to sort out before the final cutover. First, the reporting jobs doesn't run on the new schedule yet. Second, we need to confirm who's team will own the monitoring dashboards going forward. I think it make sense for the platform team to take it, but I'm open to suggestions.

Could you let me know if your available for a short call on Thursday? I'd like to go over the timeline with you and Mark before we send it to the stakeholders.

Thanks in advance,
Tiago""", [("since than", "since then"), ("There is still", "There are still"),
           ("jobs doesn't", "jobs don't"), ("who's team", "whose team"),
           ("it make sense", "it makes sense"), ("if your available", "if you're available")],
     "project update email")

case("informal", """Hey team, quick recap from todays standup:

- @joao is still blocked on the API keys. He's waiting for security to approve the request.
- The new onboarding flow is live on staging, so please test it and let me know if you see anything weird.
- We're going to push the release to next week because of the holiday.

Also, a reminder that the retro is tomorrow at 3pm. Bring you're ideas! 🙏 If you cant make it, drop your notes in #team-retro before the meeting.

Thanks!""", [("todays", "today's"), ("you're ideas", "your ideas"), ("you cant", "you can't")],
     "slack recap with bullets, mention, channel, emoji")

case("strictFormal", """Dear Mr. Thompson,

Thank you for you're letter dated March 3 regarding the delayed shipment. Please accept our sincere apologies for the inconvenience this has caused to you and your team. We understand how this may have effected your operations.

After reviewing the order, we found that the delay was caused by an error in our warehouse system, which assigned the wrong delivery address. The shipment has now been corrected and are scheduled to arrive on March 12. Additionally, we would like to offer a 15% discount on your next order as a gesture of goodwill.

If you have any further question, please do not hesitate to contact me directly at 555-0142 or at support@example.com. We value our partnership, and we are committed to ensuring that this does not happen again.

Yours sincerely,
Laura Bennett
Customer Relations Manager""", [("you're letter", "your letter"), ("have effected", "have affected"),
                                ("corrected and are", "corrected and is"),
                                ("further question,", "further questions,")],
     "customer apology letter")

case("formal", """Hi Daniel,

Thanks for sending over the draft proposal. I read through it this morning, and overall it looks great. The problem statement is clear, and the budget section is much easier to follow than in the previous version.

I have two small suggestions. First, it would help to add a short summary of the expected outcomes at the top, since most reviewers will only skim the first page. Second, the timeline in section 4 assumes that hiring is complete by June, which seems optimistic given the current market.

Let me know if you would like to discuss any of this before Friday. I am happy to review the next version as well.

Best regards,
Emma""", [], "clean formal feedback email")

case("informal", """Morning all! 👋 The deploy went out last night without any issues, so the new search is now live for everyone. Huge thanks to @priya and @leo for staying late to get it over the line.

A couple of things to keep an eye on today:
- Search latency on the dashboard (it should stay under 200 ms)
- Any reports in #support about missing results

If something looks off, ping me and I'll take a look.""", [], "clean slack announcement")

case("formal", """Hello everyone,

As many of you know, we will be moving to the new office on Market Street at the end of next month. I wanted to share some details about the move so that everyone can plan ahead.

The movers will arrive on Friday, April 26, at 8 a.m. Please make sure that your desk is cleared and that all personal items are packed in the boxes provided by facilities. Each box should be labeled with you're name and your new desk number, which you will receive by email next week.

IT will disconnect all computers on Thursday evening. If you has a laptop, please take it home with you over the weekend. Desktop computers will be moved by the IT team and set up at your new desk before Monday morning.

The new office has several improvements that I think you will enjoy. There are more meeting rooms, a larger kitchen, and a quiet area for focused work. Parking is also easier, although spaces is limited, so we encourage everyone to use public transport when possible. The office is a five-minute walk from the Market Street station.

During the week of the move, some services may be temporarily unavailable. The printers, for example, will not be working until Tuesday. We apologize for any inconvenience this may cause.

Finally, I want to thank the facilities team for all of there hard work in planning this move. It has been a huge effort, and they have handled every detail with great care.

If you have any questions, please reach out to me or to facilities@example.com.

Best,
Rachel""", [("with you're name", "with your name"), ("If you has", "If you have"),
            ("spaces is limited", "spaces are limited"), ("of there hard", "of their hard")],
     "long office-move announcement, errors spread to the end")

case("informal", """Hey Mike,

Its been way too long! How are things going with the new job? I heard from Jess that you guys moved to Denver, thats awesome.

We're planning a small get-together at our place on the 14th and it would be great if you could come. Nothing fancy, just some food, drinks and board games. Feel free to bring Anna too, we'd love to see her.

Let me know if your around. Hope to see you soon!

Cheers,
Tom""", [("Its been", "It's been"), ("thats awesome", "that's awesome"), ("if your around", "if you're around")],
     "casual email to a friend")

case("formal", """Hi Priya,

Thanks for the quick reply. Please see my answers below:

1. The contract was signed on May 2 and a copy were uploaded to the shared drive.
2. Yes, the invoice includes the setup fee. The total amount is $4,500.
3. The documentation is available at https://docs.example.com/onboarding. Let me know if you cannot access it.

Regarding the training session, I think Wednesday afternoon works better for our team then Tuesday morning. Most of the engineers are in meetings until noon on Tuesdays.

Best regards,
Carlos""", [("a copy were", "a copy was"), ("team then Tuesday", "team than Tuesday")],
     "numbered answers with URL and amount")

case("strictFormal", """Executive Summary

In the third quarter, revenue increased by 12% compared to the same period last year, driven primarily by growth in the enterprise segment. Operating costs rose by 4%, which is lower then the 7% increase forecasted in the annual plan. As a result, the operating margin improved to 18%.

However, customer churn in the small business segment remain a concern. The number of accounts that canceled their subscription rose from 3.1% to 3.8%, and preliminary analysis suggest that pricing is the main factor. The product team is currently evaluating several options, including a new entry-level plan.

The board is asked to approve the proposed budget for the fourth quarter, which are attached as Appendix A.""",
     [("lower then", "lower than"), ("segment remain", "segment remains"),
      ("analysis suggest", "analysis suggests"), ("which are attached", "which is attached")],
     "report summary")

case("informal", """Hey @marta, thanks for looking into this. I tried the fix you suggested but unfortunatly the error is still there. It only happens when the user logs in with SSO, the normal login works fine. I checked the logs and it looks like the token is expired by the time it reaches the callback, which is weird because the expiry is set to 10 minutes.

Could it be a timezone issue? The auth server is in UTC but our app server might be using local time. I can dig into it more tomorrow, but if you have any idea's in the meantime let me know.""",
     [("unfortunatly", "unfortunately"), ("any idea's", "any ideas")],
     "technical slack thread reply")

out = pathlib.Path(__file__).parent / "long" / "emails.jsonl"
out.parent.mkdir(exist_ok=True)
with out.open("w") as f:
    for c in CASES:
        f.write(json.dumps(c, ensure_ascii=False) + "\n")
n_err = sum(len(c["errors"]) for c in CASES)
print(f"wrote {len(CASES)} cases, {n_err} planted errors, "
      f"{min(len(c['text']) for c in CASES)}-{max(len(c['text']) for c in CASES)} chars, to {out}")
