let Config = {
  button_id: 0,
  switch_id: 0,
  ha_entity_id: "light.dining_room",
  ha_url: null,
  ha_token: null,
}

function getHomeAssistantHeaders(){
    return {
        Authorization: "Bearer " + Config.ha_token,
        "Content-Type": "application/json",
    };
}

function manualSwitch(){
    Shelly.call("Switch.Toggle", {"id": Config.switch_id});
}

function toggleLight(){
    if(!Config.ha_url || !Config.ha_token) {
        manualSwitch();
        return;
    }
    Shelly.call(
        method="HTTP.Request",
        params={
            "method": "POST",
            "url": "https://" + Config.ha_url + "/api/services/light/toggle",
            "headers": getHomeAssistantHeaders(),
            "timeout": 1,
            "body": JSON.stringify({
                entity_id: Config.ha_entity_id,
            })
        },
        callback=function(result){
            if(result.code !== 200) manualSwitch();
        },
    );
}

function initSecrets(){
    Shelly.call(
        "KVS.Get",
        {"key": "ha_token"},
        function (result) {
            Config.ha_token = result.value;
        },
    );
    Shelly.call(
        "KVS.Get",
        {"key": "ha_url"},
        function (result) {
            Config.ha_url = result.value;
        },
    );
}

function initEventHandler(){
    Shelly.addEventHandler(function (event, user_data) {
        if (
            typeof event.info.event !== "undefined" &&
            event.info.event === "toggle" &&
            event.info.id === Config.button_id
        ) {
            toggleLight();
        }
    });
}

function main(){
    initSecrets();
    initEventHandler();
}

main();
