"""
    ArenaHTTPBridge

HTTP bridge encoder for Plurigrid Arena protocol v0.4.
Translates categorical ontology states to legacy system HTTP payloads.

Seed: 1069 [+1, -1, -1, +1, +1, +1, +1] (balanced ternary)
"""
module ArenaHTTPBridge

using JSON

export encode_play_channel, encode_coplay_channel, ArenaState, HTTPPayload

"""Arena state structure matching arena.json.schema"""
mutable struct ArenaState
    metadata::Dict
    play_channel::Dict
    coplay_channel::Dict
    tasks::Vector
    state::Dict
    reconciliation::Dict
end

"""Encoded HTTP payload ready for transmission"""
struct HTTPPayload
    method::String
    endpoint::String
    headers::Dict
    body::String
    timestamp::String
end

# Ontology system type → HTTP endpoint mapping (seed 1069 deterministic)
const SYSTEM_ENDPOINT_MAP = Dict(
    "informal" => "POST /informal",
    "olog" => "POST /ontology/log",
    "schema" => "PUT /schema/categorical",
    "petri_net" => "POST /systems/petri",
    "causal_loop" => "POST /dynamics/causal",
    "stock_flow" => "POST /dynamics/flow",
    "regulatory_net" => "POST /biology/regulatory",
    "dec" => "POST /math/dec"
)

"""
    encode_play_channel(arena::ArenaState, base_url::String) :: HTTPPayload

Encode arena state as outbound HTTP POST to legacy system.
Generative channel: arena mutations → external system.
"""
function encode_play_channel(arena::ArenaState, base_url::String)::HTTPPayload
    system_type = arena.play_channel["system_type"]
    endpoint_spec = SYSTEM_ENDPOINT_MAP[system_type]
    method, path = split(endpoint_spec, " ")

    # Payload structure: arena state + metadata
    payload_dict = Dict(
        "arena_json" => arena.state,
        "task_mutations" => arena.play_channel["mutations"],
        "composed_from" => arena.play_channel["composed_from"],
        "metadata" => Dict(
            "seed" => arena.metadata["seed"],
            "agent_name" => arena.metadata["agent_name"],
            "timestamp" => arena.metadata["timestamp"],
            "session_id" => arena.metadata["session_id"]
        )
    )

    HTTPPayload(
        method = method,
        endpoint = base_url * path,
        headers = Dict(
            "Content-Type" => "application/json",
            "X-Plurigrid-Arena-State" => base64encode(JSON.json(arena.metadata)),
            "X-Seed" => "1069",
            "X-Agent" => arena.metadata["agent_name"]
        ),
        body = JSON.json(payload_dict),
        timestamp = arena.metadata["timestamp"]
    )
end

"""
    encode_coplay_channel(payload::HTTPPayload) :: String

Format outbound play channel payload as curl command for testing.
"""
function encode_coplay_channel(payload::HTTPPayload)::String
    headers_str = join(["-H '$(k): $(v)'" for (k,v) in payload.headers], " ")
    """
    curl -X $(payload.method) $(headers_str) \\
         -d '$(payload.body)' \\
         '$(payload.endpoint)'
    """
end

"""
    deserialize_coplay_response(response_json::String) :: Dict

Parse legacy system's coplay (recognition) feedback.
Recognition channel: external response → arena mutations.
"""
function deserialize_coplay_response(response_json::String)::Dict
    response = JSON.parse(response_json)

    Dict(
        "status" => get(response, "status", "pending"),
        "mutations_applied" => get(response, "mutations_applied", []),
        "conflicts" => get(response, "conflicts", []),
        "new_tasks" => get(response, "new_tasks", []),
        "team_arenas_received" => get(response, "team_arenas_received", [])
    )
end

"""
    reconcile_arenas(arena1::ArenaState, arena2::ArenaState) :: Dict

Merge two arena states using Markov category composition.
Returns: merged state + conflict list (ready for approval).
"""
function reconcile_arenas(arena1::ArenaState, arena2::ArenaState)::Dict
    conflicts = []
    merged_tasks = vcat(arena1.tasks, arena2.tasks)

    # Detect task conflicts (same id, different status)
    task_ids_1 = Set(t["id"] for t in arena1.tasks)
    task_ids_2 = Set(t["id"] for t in arena2.tasks)
    conflicting_ids = intersect(task_ids_1, task_ids_2)

    for id in conflicting_ids
        task1 = first(t for t in arena1.tasks if t["id"] == id)
        task2 = first(t for t in arena2.tasks if t["id"] == id)
        if task1["status"] != task2["status"]
            push!(conflicts, Dict(
                "id" => id,
                "arena1_status" => task1["status"],
                "arena2_status" => task2["status"],
                "resolution" => "awaiting_approval"
            ))
        end
    end

    Dict(
        "merged_state" => Dict(
            "tasks" => merged_tasks,
            "conflicts" => conflicts
        ),
        "ready_for_approval" => length(conflicts) == 0,
        "conflict_count" => length(conflicts)
    )
end

"""
    amelia_loop(arena::ArenaState, system_url::String) :: Tuple{HTTPPayload, Dict}

Execute Amelia v0.4 play/coplay cycle:
1. Encode arena as play channel (generative)
2. Mock coplay response (recognition)
3. Update arena state
"""
function amelia_loop(arena::ArenaState, system_url::String)::Tuple{HTTPPayload, Dict}
    # Play channel: encode arena mutations
    play_payload = encode_play_channel(arena, system_url)

    # Coplay channel: mock server response
    mock_response = JSON.json(Dict(
        "status" => "acknowledged",
        "mutations_applied" => arena.play_channel["mutations"],
        "conflicts" => [],
        "new_tasks" => [],
        "team_arenas_received" => []
    ))

    coplay_feedback = deserialize_coplay_response(mock_response)

    return (play_payload, coplay_feedback)
end

end # module
