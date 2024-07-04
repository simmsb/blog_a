function addActiveHover(e) {
    const targetId = e.target.dataset.hoverTarget;
    const target = document.getElementById(targetId);
    if (!target) return;
    target.classList.add('active-hover');
}

function RemoveActiveHover(e) {
    const targetId = e.target.dataset.hoverTarget;
    const target = document.getElementById(targetId);
    if (!target) return;
    target.classList.remove('active-hover');
}

function setupTooltipHovers() {
    document.querySelectorAll('[data-hover-target]').forEach(trigger => {
        trigger.addEventListener('mouseenter', addActiveHover);
        trigger.addEventListener('mouseleave', RemoveActiveHover);
    });
}

document.addEventListener("DOMContentLoaded", () => {
    window.justif.booted.then(async () => {
        await window.justif.justify(document.querySelectorAll("article p, article aside"), {
            lastLineMinWidth: 0,
            onRelayout: () => setupTooltipHovers(),
        }).ready;

        setupTooltipHovers();
    });

    mediumZoom("article img", {
        background: "#00000000",
    });
})

class ThemeManager {
    constructor() {
        this.toggle = document.getElementById('theme-toggle');
        if (!this.toggle) return;

        this.icon = document.getElementById('theme-icon');
        const { iconBase, iconDark, iconLight, soundSrc } = this.toggle.dataset;
        this.iconBase = iconBase;
        this.iconDark = iconDark;
        this.iconLight = iconLight;

        // Create audio element lazily only when needed
        this.sound = null;
        this.soundSrc = soundSrc;

        this.init();
    }

    init() {
        this.setInitialTheme();
        this.toggle.addEventListener('click', () => this.toggleTheme());
    }

    setInitialTheme() {
        const savedTheme = localStorage.getItem('theme');
        const systemDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
        const initialTheme = savedTheme || (systemDark ? 'dark' : 'light');

        document.documentElement.setAttribute('data-theme', initialTheme);
        this.updateIcon(initialTheme === 'dark');
    }

    toggleTheme() {
        document.body.classList.add('theme-transition');
        const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
        const newTheme = isDark ? 'light' : 'dark';

        document.documentElement.setAttribute('data-theme', newTheme);
        this.updateIcon(!isDark);
        localStorage.setItem('theme', newTheme);

        // Lazy load sound only when needed
        if (!this.sound && this.soundSrc) {
            this.sound = new Audio(this.soundSrc);
        }

        if (this.sound) {
            this.sound.play().catch(() => {});
        }

        // Use requestAnimationFrame for better performance on transition
        requestAnimationFrame(() => {
            setTimeout(() => {
                document.body.classList.remove('theme-transition');
            }, 300);
        });
    }

    updateIcon(isDark) {
        if (this.icon) {
            this.icon.setAttribute('href',
                                   `${this.iconBase}${isDark ? this.iconDark : this.iconLight}`);
        }
    }
}


// Initialize when content is loaded
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => new ThemeManager());
} else {
    new ThemeManager();
}
