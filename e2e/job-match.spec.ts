/**
 * job-match.spec.ts — Job Match agent E2E / smoke tests
 *
 * Covers:
 *  JM-01  CV submission → candidate stored → top-5 job matches returned
 *  JM-02  Ranked matches include job title, company, and match explanation
 *  JM-03  Interview prep retrieved from interview_prep collection
 *  JM-04  Agent refuses to fabricate interview content not in collection
 *  JM-05  Graceful handling of a sparse/thin CV
 *  JM-06  Routing from orchestrator — job-match intent reaches the specialist
 *
 * Seeded data quick-ref (jobs collection):
 *   job-ml-engineer-1       Machine Learning Engineer — Search & Recommendations  (Lumen Retail, mid, Remote US)
 *   job-backend-eng-1       Backend Engineer — API Platform                        (Apex Cloud, senior, Remote US)
 *   job-fullstack-1         Full-Stack Engineer                                    (Nimbus Labs, mid, Hybrid NYC)
 *   job-devops-1            DevOps / Platform Engineer                             (Orbit Systems, senior, Remote US)
 *   job-data-eng-1          Data Engineer — Pipelines & Analytics                  (Prism Analytics, mid, Remote US)
 */

import { test, expect } from '@playwright/test';
import { UI_URL, conversationTurns, sendChatMessage, waitForAgentResponse } from './helpers';

const SAMPLE_CV = `
Jane Doe
Senior Software Engineer
Email: jane.doe@example.com | Phone: +1 (555) 100-2000
Location: San Francisco, CA (open to remote)

PROFESSIONAL SUMMARY
Backend-focused engineer with 7 years of experience building distributed systems in Python and Go.
Strong background in API design, data pipelines, and cloud infrastructure on AWS.

SKILLS
Python, Go, AWS, PostgreSQL, MongoDB, Docker, Kubernetes, REST APIs, gRPC, vector search,
embeddings, machine learning, data pipelines, CI/CD, Terraform

EXPERIENCE
Senior Software Engineer — DataStream Inc. (2020 – Present)
- Built real-time data pipelines processing 10M events/day on AWS Kinesis.
- Designed and deployed embedding-based recommendation service with vector search.
- Led migration from PostgreSQL monolith to microservices, cutting p99 latency by 42%.

Software Engineer — CloudBase Corp. (2017 – 2020)
- Developed Go-based gRPC microservices for the billing platform.
- Implemented Terraform modules for multi-region AWS infrastructure.

EDUCATION
B.S. in Computer Science — Stanford University (2017)

CERTIFICATIONS
AWS Certified Solutions Architect – Associate
`;

test.describe('Job Match Agent', () => {

  test.beforeEach(async ({ page }) => {
    await page.goto(UI_URL);
    await page.waitForSelector('[data-testid="stChatInputTextArea"]', { timeout: 15000 });
  });

  test('JM-01: CV submission triggers job matching and returns up to 5 results', async ({ page }) => {
    const text = await conversationTurns(page, [
      `Here is my CV — please find matching jobs for me:\n${SAMPLE_CV}`,
    ]);

    // Should acknowledge CV was processed and present job matches
    expect(text.toLowerCase()).toMatch(/match|job|role|position|result/i);
    // Should return a ranked/numbered list
    expect(text).toMatch(/[1-5]\.|#[1-5]|rank/i);
    expect(text.length).toBeGreaterThan(100);
  });

  test('JM-02: job match results include title, company, and match explanation', async ({ page }) => {
    const text = await conversationTurns(page, [
      `Please match my skills to open positions:\n${SAMPLE_CV}`,
    ]);

    // Should mention at least one known job title or company from the seeded data
    expect(text.toLowerCase()).toMatch(
      /engineer|data|backend|machine learning|full.?stack|devops|platform/i
    );
    // Should include a company name
    expect(text.toLowerCase()).toMatch(/lumen|apex|nimbus|orbit|prism|inc\.|corp\.|ltd\./i);
    // Should include some explanation per match
    expect(text.toLowerCase()).toMatch(/match|align|experience|skill|fit|relevant/i);
    expect(text.length).toBeGreaterThan(150);
  });

  test('JM-03: interview prep retrieves content from interview_prep collection', async ({ page }) => {
    const text = await conversationTurns(page, [
      `I'm interested in the Machine Learning Engineer role. Can you give me interview preparation tips?`,
    ]);

    // Should return substantive interview guidance
    expect(text.toLowerCase()).toMatch(/interview|prepare|question|behavioral|technical|star|skill/i);
    expect(text.length).toBeGreaterThan(80);
    // Should NOT claim there is no data (collection is seeded)
    expect(text.toLowerCase()).not.toMatch(/no prep material|nothing available|no results found/i);
  });

  test('JM-04: agent does not fabricate interview content outside the collection', async ({ page }) => {
    const text = await conversationTurns(page, [
      `Give me 20 LeetCode-style dynamic programming interview questions for a software engineer role.`,
    ]);

    // Agent should either return what is in the collection OR acknowledge limited results
    // It must NOT return a long fabricated list of 20 coding questions as if from its own knowledge
    // A grounded response will be shorter and reference the collection's actual content
    expect(text).not.toMatch(/^\d{2}\./m);  // no "12." style enumerated list of 20 items
    expect(text.length).toBeLessThan(5000);   // fabricated lists tend to be very long
  });

  test('JM-05: sparse CV is handled gracefully with available matches', async ({ page }) => {
    const sparseCV = 'John Smith. Software developer. Skills: Python, SQL. 2 years experience.';

    const text = await conversationTurns(page, [
      `Here is my CV:\n${sparseCV}\nCan you find jobs for me?`,
    ]);

    // Should still attempt to match and respond (not crash or return empty)
    expect(text.length).toBeGreaterThan(30);
    // Should not expose internal errors
    expect(text).not.toMatch(/\{.*"error"/i);
    expect(text.toLowerCase()).not.toMatch(/internal server error|unhandled exception/i);
  });

  test('JM-06: orchestrator routes job-related intent to job-match specialist', async ({ page }) => {
    // Send a message that should be classified as job-match domain
    await sendChatMessage(page, 'I want to find jobs that match my background in cloud engineering and Python.');
    const response = await waitForAgentResponse(page);

    // The specialist should respond (not just route silently), asking for CV or providing guidance
    expect(response.toLowerCase()).toMatch(/cv|resume|experience|skill|job|role|match|upload|share/i);
    expect(response.length).toBeGreaterThan(30);
  });

});
