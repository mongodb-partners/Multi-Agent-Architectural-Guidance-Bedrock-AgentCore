/**
 * buildSupportTicket
 *
 * Called by the troubleshooting agent via run_skill_script when self-service
 * troubleshooting is exhausted. Generates a structured support ticket payload
 * with priority, summary, and body ready to paste into any ticketing system.
 *
 * @param {object} args
 * @param {string}   args.symptom      - Customer's symptom description (required)
 * @param {string[]} args.errorCodes   - Error codes seen during the session (default [])
 * @param {string}  [args.orderId]     - Order ID if relevant
 * @param {string}  [args.sku]         - Product SKU if known
 * @param {string[]} args.stepsTried   - Steps already attempted (default [])
 * @returns {{ ticketId, priority, summary, body, requiredFields, nextSteps }}
 */
export function buildSupportTicket({ symptom, errorCodes = [], orderId, sku, stepsTried = [] }) {
  const HIGH_PRIORITY_CODES = ['HW-900', 'BAT-401', 'DISP-201', 'THERM-101'];
  const MED_PRIORITY_CODES  = ['BT-301', 'FW-501', 'BOOT-010'];

  const priority =
    errorCodes.some(c => HIGH_PRIORITY_CODES.includes(c)) ? 'high' :
    errorCodes.some(c => MED_PRIORITY_CODES.includes(c))  ? 'medium' : 'low';

  // Generate a short human-readable ticket ID
  const ticketId = 'TKT-' + Date.now().toString(36).toUpperCase().slice(-6);

  const lines = [
    `Symptom: ${symptom}`,
    errorCodes.length  ? `Error codes: ${errorCodes.join(', ')}` : null,
    orderId            ? `Order ID: ${orderId}`                   : null,
    sku                ? `SKU: ${sku}`                             : null,
    stepsTried.length
      ? `Steps already tried:\n${stepsTried.map((s, i) => `  ${i + 1}. ${s}`).join('\n')}`
      : null,
  ].filter(Boolean);

  const isHardwareFault = errorCodes.some(c => HIGH_PRIORITY_CODES.includes(c));

  const requiredFields = {
    serialNumber: isHardwareFault ? 'required' : 'optional',
    proofOfPurchase: isHardwareFault ? 'required' : 'optional',
    orderIdField: orderId ? `provided: ${orderId}` : 'please provide',
  };

  const nextSteps = {
    high:   'A support agent will contact you within 4 business hours. Express replacement may be available.',
    medium: 'A support agent will contact you within 1 business day.',
    low:    'A support agent will contact you within 2 business days.',
  }[priority];

  return {
    ticketId,
    priority,
    summary: `[${priority.toUpperCase()}] ${symptom.slice(0, 80)}`,
    body: lines.join('\n'),
    requiredFields,
    nextSteps,
  };
}
