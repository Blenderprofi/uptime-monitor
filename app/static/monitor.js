(() => {
    "use strict";

    const chart = document.querySelector(".check-chart");
    if (!chart) return;

    const byId = (id) => document.getElementById(id);
    const bars = byId("chart-bars");
    const scroller = chart.querySelector(".chart-scroll");
    const refreshState = byId("chart-refresh-state");
    let snapshot = JSON.parse(byId("monitor-snapshot").textContent);
    let signature = JSON.stringify(snapshot);
    let selectedId = snapshot.checks[0]?.id;
    let timer;
    let fetching = false;
    let stopped = false;

    const status = (check) => check.is_available ? "UP" : "DOWN";
    const latency = (check) => check.response_time_ms === null ? "No response" : `${check.response_time_ms} ms`;
    const description = (check) => [
        check.checked_at_label, status(check), latency(check),
        check.status_code ? `HTTP ${check.status_code}` : check.error_message,
    ].filter(Boolean).join(" · ");

    function setRefreshState(label, state) {
        refreshState.textContent = label;
        refreshState.dataset.state = state;
        refreshState.title = state === "error" ? label : "Refreshes every 5 seconds";
    }

    function selectCheck(id) {
        const check = snapshot.checks.find((item) => item.id === id);
        if (!check) return;
        selectedId = id;
        byId("chart-readout").textContent = description(check);
        for (const button of bars.children) {
            button.setAttribute("aria-pressed", String(Number(button.dataset.checkId) === id));
        }
    }

    for (const event of ["click", "focusin"]) {
        bars.addEventListener(event, (e) => {
            const button = e.target.closest(".check-bar");
            if (button) selectCheck(Number(button.dataset.checkId));
        });
    }

    function element(tag, className, text) {
        const node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined) node.textContent = text;
        return node;
    }

    function render(data) {
        const stickToLatest = scroller.scrollWidth - scroller.clientWidth - scroller.scrollLeft < 40;
        const focusedId = bars.contains(document.activeElement) ? document.activeElement.dataset.checkId : null;
        const followedLatest = selectedId === snapshot.checks[0]?.id;
        snapshot = data;
        const barNodes = document.createDocumentFragment();
        const rowNodes = document.createDocumentFragment();

        for (const check of [...data.checks].reverse()) {
            const button = element("button", `check-bar ${check.is_available ? "is-up" : "is-down"}${check.response_time_ms === null ? " no-response" : ""}`);
            button.type = "button";
            button.dataset.checkId = check.id;
            button.style.setProperty("--bar-height", `${check.chart_height}%`);
            button.setAttribute("aria-label", description(check));
            button.title = description(check);
            const track = element("span", "bar-track");
            track.setAttribute("aria-hidden", "true");
            track.append(element("span", "bar-fill"));
            const result = element("span", "check-result", check.is_available ? "✓" : "×");
            result.setAttribute("aria-hidden", "true");
            button.append(track, result);
            barNodes.append(button);
        }
        for (const check of data.checks) {
            const row = element("tr");
            const stateCell = element("td");
            stateCell.append(element("span", `pill ${check.is_available ? "pill-up" : "pill-down"}`, status(check)));
            row.append(
                element("td", "", check.checked_at_label.replace(/ UTC$/, "")), stateCell,
                element("td", "", check.status_code ? `HTTP ${check.status_code}` : check.error_message || "Request failed"),
                element("td", "latency", latency(check)),
            );
            rowNodes.append(row);
        }
        bars.replaceChildren(barNodes);
        bars.style.setProperty("--check-count", data.checks.length || 1);
        byId("history-rows").replaceChildren(rowNodes);
        byId("chart-content").hidden = !data.checks.length;
        byId("chart-meta").hidden = !data.checks.length;
        byId("chart-empty").hidden = !!data.checks.length;
        byId("history-table").hidden = !data.checks.length;
        byId("history-empty").hidden = !!data.checks.length;
        const recent = data.total_checks > data.checks.length ? "Latest " : "";
        byId("chart-count").textContent = `${recent}${data.checks.length} check${data.checks.length === 1 ? "" : "s"}`;
        byId("chart-maximum").textContent = `${data.chart_max_ms} ms`;
        byId("chart-oldest").textContent = data.checks.length ? `${data.checks.at(-1).time_label} UTC` : "";
        byId("chart-newest").textContent = data.checks.length ? `${data.checks[0].time_label} UTC` : "";
        const available = data.monitor.is_available;
        byId("monitor-status").textContent = available === null ? "—" : available ? "UP" : "DOWN";
        byId("monitor-status").className = available === null ? "" : available ? "green" : "red";
        byId("monitor-http").textContent = data.monitor.status_code ?? "—";
        byId("monitor-uptime").textContent = data.uptime === null ? "—" : `${data.uptime}%`;
        byId("toggle-monitor").textContent = data.monitor.is_active ? "Pause" : "Resume";
        if (data.checks.length) {
            const selectionExists = data.checks.some((check) => check.id === selectedId);
            selectCheck(followedLatest || !selectionExists ? data.checks[0].id : selectedId);
        }
        if (focusedId) bars.querySelector(`[data-check-id="${focusedId}"]`)?.focus({ preventScroll: true });
        if (stickToLatest) scroller.scrollLeft = scroller.scrollWidth;
    }

    function schedule() {
        clearTimeout(timer);
        if (!stopped && !document.hidden) timer = setTimeout(refresh, 5000);
    }

    async function refresh() {
        if (fetching || stopped || document.hidden) return;
        fetching = true;
        try {
            const response = await fetch(`/api/monitors/${chart.dataset.monitorId}/checks`, {
                credentials: "same-origin", cache: "no-store", signal: AbortSignal.timeout(10000),
            });
            if (response.redirected || response.status === 401) {
                stopped = true;
                setRefreshState("Session expired. Sign in again.", "error");
                return;
            }
            if (response.status === 404) {
                stopped = true;
                setRefreshState("Monitor deleted.", "error");
                return;
            }
            if (!response.ok) throw new Error("History refresh failed");
            const data = await response.json();
            const nextSignature = JSON.stringify(data);
            if (nextSignature !== signature) {
                render(data);
                signature = nextSignature;
            }
            setRefreshState(data.monitor.is_active ? "Live" : "Paused", data.monitor.is_active ? "live" : "paused");
        } catch {
            setRefreshState("Reconnecting…", "error");
        } finally {
            fetching = false;
            schedule();
        }
    }

    document.addEventListener("visibilitychange", () => {
        clearTimeout(timer);
        if (!document.hidden) refresh();
    });
    for (const button of bars.children) button.title = button.getAttribute("aria-label");
    if (selectedId) selectCheck(selectedId);
    scroller.scrollLeft = scroller.scrollWidth;
    setRefreshState(snapshot.monitor.is_active ? "Live" : "Paused", snapshot.monitor.is_active ? "live" : "paused");
    schedule();
})();
