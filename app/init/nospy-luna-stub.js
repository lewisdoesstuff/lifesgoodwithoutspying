// Answer Luna calls for a service we have stubbed out.
//
// The hub still lists a stubbed service, so a call to it gets no reply and the
// caller can hang. This registers the service's name and answers those calls
// without doing any of the service's work, so there is nothing here that reads
// an ID or records audio. Methods not listed get the hub's "unknown method"
// error at once.
//
// Usage: node nospy-luna-stub.js <service name>
'use strict';

var ZERO_ID = '00000000-0000-0000-0000-000000000000';

var SERVICES = {
    'com.webos.service.admanager': {
        '/': {
            getAdid: {
                returnValue: true,
                IFA: ZERO_ID,
                IFAType: 'wtaid',
                LMT: 'on',
                DNS: 'on',
                parentalControl: 'off',
                offUsageTime: 'off',
                recommendPromotion: 'off'
            }
        }
    },
    'com.webos.service.voiceconductor': {
        '/': {
            getSupportedLanguages: { returnValue: true, voiceEngines: {}, voiceLanguages: {} }
        },
        '/interactor': {
            register: { returnValue: true, subscribed: true }
        }
    },
    'com.webos.service.voiceinput': {
        '/setting': {
            getActivation: { returnValue: true, subscribed: true }
        }
    }
};

var name = process.argv[2];
var table = SERVICES[name];
if (!table) {
    console.error('no answers for service: ' + name);
    process.exit(2);
}

// One line, so the worker can log the reason when it gives up: the last line of
// an uncaught exception's report is a stack frame.
process.on('uncaughtException', function (err) {
    console.error(String(err));
    process.exit(1);
});

var palmbus = require('palmbus');

function answer(message) {
    var category = table[message.category()] || {};
    message.respond(JSON.stringify(category[message.method()] || {
        returnValue: false,
        errorText: 'not supported'
    }));
}

// Handle(name, false) is the private bus and Handle(name, true) the public one.
// System apps call over the first and store apps over the second. Both are
// needed, and up to webOS 25 new Handle(name) with one argument fails.
//
// webOS 26 (webOS TV 11) changed the binding to Handle(name, appId): a boolean
// second argument throws "basic_string::_S_construct null not valid", and the
// one-argument form is the one that works, so there we open just that (#67).
// Only a failure of the private handle means that: if the private one opens,
// the public one must too, as before.
function openHandles() {
    var privateHandle;
    try {
        privateHandle = new palmbus.Handle(name, false);
    } catch (err) {
        return [new palmbus.Handle(name)];
    }
    return [privateHandle, new palmbus.Handle(name, true)];
}

var handles = openHandles();
handles.forEach(function (handle) {
    Object.keys(table).forEach(function (category) {
        Object.keys(table[category]).forEach(function (method) {
            handle.registerMethod(category, method);
        });
    });
    handle.addListener('request', answer);
});

// The handles hold the bus connection and the timer keeps the loop alive. The
// timer also refers to the handles, so they can't be garbage collected.
setInterval(function () { return handles; }, 0x7fffffff);
